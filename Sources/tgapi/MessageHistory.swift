import Foundation

final class MessageHistoryStore {
    private let queue = DispatchQueue(label: "com.tgextra.editHistory", attributes: .concurrent)
    private struct EditEntry {
        var versions: [String]
        var editDate: Int32?
        var contents: [[String: Data]]
    }

    private var entries = [MessageKey: EditEntry]()
    private var originalOrder = [MessageKey]()
    private var loaded = false
    private let archive: MessageHistoryArchive
    private var dirty = Set<MessageKey>()

    init(archive: MessageHistoryArchive = .shared) { self.archive = archive }

    private var persistScheduled = false
    private var persistGeneration: UInt64 = 0
    private let storageKey = "TGExtraEditHistoryByAccount"

    private let maxTrackedOriginals = 2000
    private let maxVersionsPerMessage = 20

    func load() {
        queue.async(flags: .barrier) { [self] in _ = loadLocked() }
    }

    private func loadLocked() -> Bool {
        if loaded { return true }
        let legacy = UserDefaults.standard.dictionary(forKey: storageKey) as? [String: [String: Any]] ?? [:]
        guard archive.migrate(legacy) else { return false }
        let saved = archive.load()
        UserDefaults.standard.removeObject(forKey: storageKey)
        for (key, value) in saved {
            guard let messageKey = MessageKey(storageKey: key),
                  let versions = value["versions"] as? [String], !versions.isEmpty else { continue }
            let savedContents = value["contents"] as? [[String: Data]] ?? []
            let contents = savedContents.count == versions.count ? savedContents : Array(repeating: [:], count: versions.count)
            entries[messageKey] = EditEntry(versions: versions,
                editDate: (value["editDate"] as? NSNumber)?.int32Value, contents: contents)
            if versions.count == 1 { originalOrder.append(messageKey) }
        }
        loaded = true
        trimOriginalsLocked()
        return true
    }

    private func trimOriginalsLocked() {
        while originalOrder.count > maxTrackedOriginals {
            let key = originalOrder.removeFirst()
            entries.removeValue(forKey: key)
            dirty.remove(key)
            archive.remove(key)
        }
    }

    private func persistLocked(_ key: MessageKey) {
        guard let entry = entries[key] else { return }
        var value: [String: Any] = ["versions": entry.versions, "contents": entry.contents]
        if let date = entry.editDate { value["editDate"] = NSNumber(value: date) }
        dirty.remove(key)
        archive.save(value, key: key)
    }

    private func schedulePersistLocked() {
        guard !persistScheduled else { return }
        persistScheduled = true
        let generation = persistGeneration
        queue.asyncAfter(deadline: .now() + 5.0, flags: .barrier) { [self] in
            guard generation == persistGeneration else { return }
            persistScheduled = false
            var batch = [MessageKey: [String: Any]]()
            for key in dirty {
                guard let entry = entries[key] else { continue }
                var value: [String: Any] = ["versions": entry.versions, "contents": entry.contents]
                if let date = entry.editDate { value["editDate"] = NSNumber(value: date) }
                batch[key] = value
            }
            dirty.removeAll()
            archive.save(batch)
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
            guard loadLocked() else { return false }
            guard var entry = entries[key] else {
                entries[key] = EditEntry(versions: [text], editDate: editDate, contents: [content])
                originalOrder.append(key)
                dirty.insert(key)
                trimOriginalsLocked()
                schedulePersistLocked()
                return false
            }
            guard editDate != nil || allowUndatedEdit else { return false }
            if let date = editDate, let latestDate = entry.editDate, date < latestDate { return false }
            let previousContent = entry.contents.last ?? [:]
            let contentChanged = contentDiffers(previousContent, content, fields: ["entities", "mediaIdentity", "rich"])
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
                    if entry.versions.count > 1 { persistLocked(key) }
                    else { dirty.insert(key); schedulePersistLocked() }
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
            persistLocked(key)
            return true
        }
    }

    @discardableResult
    func clear() -> Bool {
        queue.sync(flags: .barrier) {
            guard archive.clear() else { return false }
            loaded = true
            entries.removeAll()
            dirty.removeAll()
            originalOrder.removeAll()
            persistGeneration &+= 1
            persistScheduled = false
            for key in [storageKey, "TGExtraEditHistoryByPeer", "TGExtraEditHistory", "TGExtraEditHistoryPeers"] {
                UserDefaults.standard.removeObject(forKey: key)
            }
            return true
        }
    }

    func discard(_ key: MessageKey) -> Bool {
        queue.sync(flags: .barrier) {
            guard entries.removeValue(forKey: key) != nil else { return false }
            originalOrder.removeAll { $0 == key }
            dirty.remove(key)
            archive.remove(key)
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
