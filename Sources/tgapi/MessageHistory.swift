import Foundation

struct MessageKey: Hashable {
    let account: String
    let peer: Int64
    let id: Int32
    let namespace: Int32

    var storageKey: String {
        let base = "\(account):\(peer):\(id)"
        return namespace == 0 ? base : "\(base):\(namespace)"
    }

    init(account: String, peer: Int64, id: Int32, namespace: Int32 = 0) {
        self.account = account
        self.peer = peer
        self.id = id
        self.namespace = namespace
    }

    init?(storageKey: String) {
        let parts = storageKey.split(separator: ":")
        guard parts.count == 3 || parts.count == 4,
              let peer = Int64(parts[1]), let id = Int32(parts[2]) else { return nil }
        self.account = String(parts[0])
        self.peer = peer
        self.id = id
        if parts.count == 4 {
            guard let namespace = Int32(parts[3]) else { return nil }
            self.namespace = namespace
        } else { self.namespace = 0 }
    }
}

// Owns revision retention, ordering and persistence. The parser supplies message identity and content.
final class MessageHistoryStore {
    private let queue = DispatchQueue(label: "com.tgextra.editHistory", attributes: .concurrent)
    private struct EditEntry {
        var versions: [String]
        var editDate: Int32?
        var contents: [[String: Data]]
    }

    private var entries = [MessageKey: EditEntry]()
    // Only unedited originals can be evicted; unrelated traffic must not erase
    // versions which cannot be fetched again.
    private var originalOrder = [MessageKey]()
    private var loaded = false
    private var persistScheduled = false
    private var persistGeneration: UInt64 = 0
    private let storageKey = "TGExtraEditHistoryByAccount"
    // Older keys are left intact. Their entries have no account identity and
    // cannot safely be attributed to any of the current accounts.

    private let maxTrackedOriginals = 2000
    private let maxVersionsPerMessage = 20

    func load() {
        queue.async(flags: .barrier) { [self] in
            guard !loaded else { return }
            loaded = true
            guard let saved = UserDefaults.standard.dictionary(forKey: storageKey) as? [String: [String: Any]] else { return }
            for (key, value) in saved {
                guard let editKey = MessageKey(storageKey: key),
                      let versions = value["versions"] as? [String], !versions.isEmpty else { continue }
                let savedContents = value["contents"] as? [[String: Data]] ?? []
                let contents = savedContents.count == versions.count ? savedContents : Array(repeating: [:], count: versions.count)
                entries[editKey] = EditEntry(versions: versions,
                    editDate: (value["editDate"] as? NSNumber)?.int32Value, contents: contents)
                if versions.count == 1 { originalOrder.append(editKey) }
            }
            trimOriginalsLocked()
        }
    }

    /// Must be called with the edit barrier held.
    private func trimOriginalsLocked() {
        while originalOrder.count > maxTrackedOriginals {
            entries.removeValue(forKey: originalOrder.removeFirst())
        }
    }

    /// Writes the whole map out. Must be called with the barrier held.
    private func persistLocked() {
        var out = [String: [String: Any]]()
        for (key, entry) in entries {
            var value: [String: Any] = ["versions": entry.versions, "contents": entry.contents]
            if let date = entry.editDate { value["editDate"] = NSNumber(value: date) }
            out[key.storageKey] = value
        }
        UserDefaults.standard.set(out, forKey: storageKey)
    }

    /// Coalesced write-back, for recording originals. Must be called with the
    /// barrier held.
    ///
    /// An original is recorded for *every* message that passes through, so
    /// persisting each one eagerly would mean a UserDefaults write per message.
    /// An original not yet flushed can be lost if the app is killed before
    /// this write, so keep the delay short.
    private func schedulePersistLocked() {
        guard !persistScheduled else { return }
        persistScheduled = true
        let generation = persistGeneration
        queue.asyncAfter(deadline: .now() + 5.0, flags: .barrier) { [self] in
            guard generation == persistGeneration else { return }
            persistScheduled = false
            persistLocked()
        }
    }

    private func contentDiffers(_ lhs: [String: Data], _ rhs: [String: Data], fields: [String]) -> Bool {
        return fields.contains { field in
            guard let before = lhs[field], let after = rhs[field] else { return false }
            return before != after
        }
    }

    func record(_ text: String, key: MessageKey, editDate: Int32?,
                allowUndatedEdit: Bool = false, content: [String: Data],
                localSnapshot: Bool = false) -> Bool {
        return queue.sync(flags: .barrier) {
            guard var entry = entries[key] else {
                entries[key] = EditEntry(versions: [text], editDate: editDate, contents: [content])
                originalOrder.append(key)
                trimOriginalsLocked()
                schedulePersistLocked()
                return false
            }
            guard editDate != nil || allowUndatedEdit else { return false }
            if let date = editDate, let latestDate = entry.editDate, date < latestDate { return false }
            let previousContent = entry.contents.last ?? [:]
            let contentChanged = contentDiffers(previousContent, content, fields: ["entities", "mediaIdentity", "rich"])
            // UI can still display the previous item while a network edit is
            // already recorded. Equal second-resolution dates cannot establish
            // that a different cache snapshot is newer. Network updates retain
            // their existing arrival-order handling for equal dates.
            if localSnapshot, let latestDate = entry.editDate {
                guard let date = editDate else { return false }
                if date <= latestDate && (entry.versions.last != text || contentChanged) { return false }
            }
            let dateChanged = editDate != nil && entry.editDate != editDate
            if let date = editDate { entry.editDate = date }
            guard entry.versions.last != text || contentChanged else {
                let merged = previousContent.merging(content) { _, observed in observed }
                let learnedContent = merged != previousContent
                if learnedContent { entry.contents[entry.contents.count - 1] = merged }
                if dateChanged || learnedContent {
                    entries[key] = entry
                    if entry.versions.count > 1 { persistLocked() }
                    else { schedulePersistLocked() }
                }
                return false
            }
            if entry.versions.count == 1 { originalOrder.removeAll { $0 == key } }
            entry.versions.append(text)
            entry.contents.append(content)
            if entry.versions.count > maxVersionsPerMessage {
                let removed = 1..<(entry.versions.count - maxVersionsPerMessage + 1)
                entry.versions.removeSubrange(removed)
                entry.contents.removeSubrange(removed)
            }
            entries[key] = entry
            persistLocked()
            return true
        }
    }

    func clear() {
        queue.sync(flags: .barrier) {
            loaded = true
            entries.removeAll()
            originalOrder.removeAll()
            persistGeneration &+= 1
            persistScheduled = false
            for key in [storageKey, "TGExtraEditHistoryByPeer", "TGExtraEditHistory", "TGExtraEditHistoryPeers"] {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }
    }

    func discard(_ key: MessageKey) -> Bool {
        queue.sync(flags: .barrier) {
            guard entries.removeValue(forKey: key) != nil else { return false }
            originalOrder.removeAll { $0 == key }
            persistLocked()
            return true
        }
    }

    func versions(for key: MessageKey) -> [String]? {
        queue.sync {
            guard let versions = entries[key]?.versions, versions.count > 1 else { return nil }
            return versions
        }
    }

    func details(for key: MessageKey) -> [[String: Any]]? {
        return queue.sync {
            guard let entry = entries[key], entry.versions.count > 1 else { return nil }
            return entry.contents.enumerated().map { index, content in
                let previous = index > 0 ? entry.contents[index - 1] : content
                let richFormattingChanged = index > 0 && entry.versions[index] == entry.versions[index - 1] &&
                    contentDiffers(previous, content, fields: ["rich"])
                return ["text": entry.versions[index], "content": content,
                        "mediaChanged": contentDiffers(previous, content, fields: ["mediaIdentity"]),
                        "formatChanged": contentDiffers(previous, content, fields: ["entities"]) || richFormattingChanged]
            }
        }
    }
}
