import Foundation

// Only unpinned snapshots participate in eviction. Links make touches and
// removals constant time even when deleted-message history grows indefinitely.
struct MessageSnapshotOrder {
    private struct Links { var previous: MessageKey?; var next: MessageKey? }
    private var links = [MessageKey: Links]()
    private(set) var first: MessageKey?
    private var last: MessageKey?
    var count: Int { links.count }

    mutating func remove(_ key: MessageKey) {
        guard let entry = links.removeValue(forKey: key) else { return }
        if let previous = entry.previous { links[previous]?.next = entry.next } else { first = entry.next }
        if let next = entry.next { links[next]?.previous = entry.previous } else { last = entry.previous }
    }

    mutating func append(_ key: MessageKey) {
        remove(key)
        links[key] = Links(previous: last, next: nil)
        if let last = last { links[last]?.next = key } else { first = key }
        last = key
    }
}

extension TLParser {
    static let snapshotUdKey = "TGExtraObservedMessages"

    // Access requires processingLock.
    static var snapshots = [MessageKey: Data]()
    static var snapshotOrder = MessageSnapshotOrder()
    static var snapshotPositions = [MessageKey: Int64]()
    static var snapshotPosition: Int64 = 0
    static var snapshotKeysByMarker = [MessageKey: Set<MessageKey>]()
    static var snapshotEditDates = [MessageKey: Int32]()
    static var snapshotDatesLoaded = Set<MessageKey>()
    static var dirtySnapshots = Set<MessageKey>()
    static var removedSnapshots = Set<MessageKey>()
    static var snapshotsLoaded = false
    static var snapshotWriteScheduled = false
    static var snapshotFlushRequested = false
    static var snapshotGeneration: UInt64 = 0
    static var messageArchivePrepared = false

    static func prepareMessageArchive() -> Bool {
        if messageArchivePrepared { return true }
        let defaults = UserDefaults.standard
        guard MessageHistoryArchive.shared.migrateMessageData(
            snapshots: defaults.dictionary(forKey: snapshotUdKey) ?? [:],
            markers: defaults.dictionary(forKey: markerUdKey) ?? [:]) else { return false }
        messageArchivePrepared = true
        defaults.removeObject(forKey: snapshotUdKey)
        defaults.removeObject(forKey: markerUdKey)
        return true
    }

    static func indexSnapshot(_ key: MessageKey) {
        guard let marker = markerKey(id: key.id, peer: key.peer, account: key.account, namespace: key.namespace) else { return }
        snapshotKeysByMarker[marker, default: []].insert(key)
        if markerBits(id: key.id, peer: key.peer, account: key.account, namespace: key.namespace) & deletedMarker == 0 {
            snapshotOrder.append(key)
        }
    }

    static func pinSnapshots(for marker: MessageKey) {
        for key in snapshotKeysByMarker[marker] ?? [] { snapshotOrder.remove(key) }
    }

    static func pinChannelSnapshots(account: String, peer: Int64, through id: Int32) {
        for key in snapshots.keys where key.account == account && key.peer == peer && key.namespace == 0 && key.id > 0 && key.id <= id {
            snapshotOrder.remove(key)
        }
    }

    static func loadSnapshots() {
        guard !snapshotsLoaded, prepareMessageArchive() else { return }
        loadMarkers()
        for row in MessageHistoryArchive.shared.loadSnapshots() {
            snapshots[row.key] = row.bytes
            snapshotPositions[row.key] = row.position
            snapshotPosition = max(snapshotPosition, row.position)
            indexSnapshot(row.key)
        }
        snapshotsLoaded = true
        trimSnapshots()
        if !removedSnapshots.isEmpty { scheduleSnapshotWrite() }
    }

    static func writeSnapshots() {
        snapshotFlushRequested = true
        if markerBatchDepth == 0 { flushMarkers() }
    }

    static func flushMessageData() {
        let rows = dirtySnapshots.compactMap { key -> MessageSnapshotRow? in
            guard let bytes = snapshots[key], let position = snapshotPositions[key] else { return nil }
            return MessageSnapshotRow(key: key, bytes: bytes, position: position)
        }
        let markers = Dictionary(uniqueKeysWithValues: dirtyMarkers.compactMap { key in messageMarkers[key].map { (key, $0) } })
        if !rows.isEmpty || !removedSnapshots.isEmpty || !markers.isEmpty {
            MessageHistoryArchive.shared.saveMessageData(snapshots: rows, removing: removedSnapshots, markers: markers)
        }
        dirtySnapshots.removeAll(); removedSnapshots.removeAll(); dirtyMarkers.removeAll()
        markersDirty = false
        snapshotFlushRequested = false
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

    static func trimSnapshots() {
        while snapshotOrder.count > 2000, let key = snapshotOrder.first {
            snapshotOrder.remove(key)
            snapshots.removeValue(forKey: key)
            snapshotPositions.removeValue(forKey: key)
            snapshotEditDates.removeValue(forKey: key)
            snapshotDatesLoaded.remove(key)
            dirtySnapshots.remove(key)
            removedSnapshots.insert(key)
            if let marker = markerKey(id: key.id, peer: key.peer, account: key.account, namespace: key.namespace) {
                snapshotKeysByMarker[marker]?.remove(key)
                if snapshotKeysByMarker[marker]?.isEmpty == true { snapshotKeysByMarker.removeValue(forKey: marker) }
            }
        }
    }

    static func cacheMessage(_ message: Api.Message) {
        guard processingNamespace == 0, let account = processingHistoryAccount,
              packetSettings.protectsAnyDeletions else { return }
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
        guard snapshotsLoaded else { return }
        let key = MessageKey(account: account, peer: peer, id: id)
        if !snapshotDatesLoaded.contains(key), let bytes = snapshots[key] {
            if case let .message(data)? = decodedSnapshot(bytes) { snapshotEditDates[key] = data.editDate }
            snapshotDatesLoaded.insert(key)
        }
        if let oldDate = snapshotEditDates[key] {
            guard let editDate = editDate, editDate >= oldDate else { return }
        }
        let bytes = serializeBoxed(message) as Data
        guard !bytes.isEmpty, snapshots[key] != bytes else { return }
        snapshots[key] = bytes
        snapshotEditDates[key] = editDate
        snapshotDatesLoaded.insert(key)
        snapshotPosition += 1
        snapshotPositions[key] = snapshotPosition
        dirtySnapshots.insert(key)
        removedSnapshots.remove(key)
        indexSnapshot(key)
        trimSnapshots()
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
            let scope = requestedMessagePeer ?? cloudScope
            let marker = MessageKey(account: account, peer: scope, id: id)
            let matches = (snapshotKeysByMarker[marker] ?? []).filter { key in
                requestedMessagePeer.map { key.peer == $0 } ?? (key.peer > -1_000_000_000_000)
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
