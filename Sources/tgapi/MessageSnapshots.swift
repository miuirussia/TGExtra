import Foundation

extension TLParser {
    static let snapshotUdKey = "TGExtraObservedMessages"

    // Access requires processingLock.
    static var snapshots = [MessageKey: Data]()

    static var snapshotOrder = [MessageKey]()

    static var snapshotsLoaded = false

    static var snapshotWriteScheduled = false

    static var snapshotGeneration: UInt64 = 0

    static func loadSnapshots() {
        guard !snapshotsLoaded else { return }
        snapshotsLoaded = true
        let saved = UserDefaults.standard.dictionary(forKey: snapshotUdKey) ?? [:]
        if let messages = saved["messages"] as? [String: Data] {
            for (raw, bytes) in messages {
                if let key = MessageKey(storageKey: raw) { snapshots[key] = bytes }
            }
        }
        snapshotOrder = (saved["order"] as? [String] ?? []).compactMap(MessageKey.init(storageKey:))
        var seen = Set<MessageKey>()
        snapshotOrder = snapshotOrder.filter { snapshots[$0] != nil && seen.insert($0).inserted }
        snapshotOrder.append(contentsOf: snapshots.keys.filter { !seen.contains($0) }.sorted { $0.storageKey < $1.storageKey })
    }

    static func writeSnapshots() {
        UserDefaults.standard.set([
            "messages": Dictionary(uniqueKeysWithValues: snapshots.map { ($0.key.storageKey, $0.value) }),
            "order": snapshotOrder.map { $0.storageKey }
        ], forKey: snapshotUdKey)
    }

    static func scheduleSnapshotWrite() {
        guard !snapshotWriteScheduled else { return }
        snapshotWriteScheduled = true
        let generation = snapshotGeneration
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 5) {
            processingLock.lock()
            defer { processingLock.unlock() }
            guard generation == snapshotGeneration else { return }
            snapshotWriteScheduled = false
            writeSnapshots()
        }
    }

    static func decodedSnapshot(_ bytes: Data) -> Api.Message? {
        let reader = BufferReader(Buffer(data: bytes))
        guard let constructor = reader.readInt32(),
              let message = Api.parse(reader, signature: constructor) as? Api.Message,
              reader.offset == UInt(bytes.count) else { return nil }
        MessagePatches.prepareDecodedObjects(in: reader)
        return message
    }

    static func cacheMessage(_ message: Api.Message) {
        guard processingNamespace == 0, let account = processingHistoryAccount else { return }
        guard packetSettings.protectsAnyDeletions else { return }
        let id: Int32
        let peer: Int64
        let editDate: Int32?
        switch message {
        case let .message(data): (id, peer, editDate) = (data.id, peerKey(data.peerId), data.editDate)
        case let .messageService(data): (id, peer, editDate) = (data.id, peerKey(data.peerId), nil)
        default: return
        }
        guard id != 0 else { return }
        loadSnapshots()
        let key = MessageKey(account: account, peer: peer, id: id)
        if let bytes = snapshots[key], let previous = decodedSnapshot(bytes), case let .message(data) = previous,
           let oldDate = data.editDate {
            guard let editDate = editDate, editDate >= oldDate else { return }
        }
        let bytes = serializeBoxed(message) as Data
        guard !bytes.isEmpty, snapshots[key] != bytes else { return }
        snapshots[key] = bytes
        snapshotOrder.removeAll { $0 == key }
        snapshotOrder.append(key)
        let unpinned = snapshotOrder.filter {
            markerBits(id: $0.id, peer: $0.peer, account: $0.account, namespace: $0.namespace) & deletedMarker == 0
        }
        let evicted = Set(unpinned.prefix(max(0, unpinned.count - 2000)))
        for key in evicted { snapshots.removeValue(forKey: key) }
        snapshotOrder.removeAll { evicted.contains($0) }
        scheduleSnapshotWrite()
    }

    static func restoreValidatedMessages(_ messages: [Api.Message]) -> ([Api.Message], Bool) {
        guard processingNamespace == 0, let account = processingHistoryAccount,
              let requested = requestedMessageIds else { return (messages, false) }
        loadSnapshots()
        var available = Set<Int32>()
        for message in messages {
            switch message {
            case let .message(data): available.insert(data.id)
            case let .messageService(data): available.insert(data.id)
            default: break
            }
        }
        var recovered = [Int32: Api.Message]()
        for id in requested where !available.contains(id) {
            let matches = snapshots.keys.filter {
                $0.account == account && $0.namespace == 0 && $0.id == id
            }.filter { key in
                if let peer = requestedMessagePeer { return key.peer == peer }
                return key.peer > -1_000_000_000_000
            }
            guard matches.count == 1, let key = matches.first, let bytes = snapshots[key],
                  let snapshot = decodedSnapshot(bytes),
                  neutralizeDeletions([id], peer: key.peer) != nil else { continue }
            recovered[id] = snapshot
        }
        guard !recovered.isEmpty else { return (messages, false) }
        writeSnapshots()
        var result = messages.map { message -> Api.Message in
            if case let .messageEmpty(data) = message, let replacement = recovered.removeValue(forKey: data.id) { return replacement }
            return message
        }
        for id in requested {
            if let replacement = recovered.removeValue(forKey: id) { result.append(replacement) }
        }
        return (result, true)
    }

    static func validationRequest(_ payload: NSData?, function: Int32) -> (ids: [Int32], peer: Int64?)? {
        guard let method = TLMethodID(signature: function),
              method == .messagesGetMessages || method == .channelsGetMessages,
              let payload = payload, let record = request(payload), record.descriptor?.signature == function,
              let inputs = record["id"] as? [TLRecord] else { return nil }
        var peer: Int64?
        if method == .channelsGetMessages {
            guard let channel = record["channel"] as? TLRecord,
                  ["inputChannel", "inputChannelFromMessage"].contains(channel.constructorName),
                  let id = channel["channelId"] as? Int64, id > 0, id <= Int64.max - 1_000_000_000_000 else { return nil }
            peer = -(1_000_000_000_000 + id)
        }
        let ids = inputs.compactMap { $0.constructorName == "inputMessageID" ? $0["id"] as? Int32 : nil }
        return (ids, peer)
    }
}
