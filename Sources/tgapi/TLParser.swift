import Foundation
import tgapiC
import os

@objc(TLParser)
class TLParser: NSObject {
    private static let cloudScope: Int64 = 0
    private static let markerUdKey = "TGExtraMessageMarkersByAccount"
    // Protected by processingLock. Keep timer classifications until explicitly
    // cleared: evicting them would silently re-enable a later server deletion.
    private static var messageMarkers = [EditKey: Int]()
    private static var markersLoaded = false
    private static var markersDirty = false
    private static var markerBatchDepth = 0
    private static let deletedMarker = 1
    private static let disappearingMarker = 2
    private static let autoDeleteMarker = 4

    private struct ContentReadState {
        var peer: Int64
        var mention: Bool?
        var reaction: Bool?
        var disappearingMedia: Bool?
    }
    // Account-scoped metadata only. Unknown/evicted entries remain blocked by
    // enabled content privacy or media protection toggles until classified.
    private static var contentReadStates = [EditKey: ContentReadState]()
    private static var contentReadOrder = [EditKey]()

    private static var tracksContentReads: Bool {
        return packetSettings.tracksContentReads
    }

    private static func noteContentReadState(id: Int32, peer: Int64, mention: Bool? = nil, reaction: Bool?, disappearingMedia: Bool? = nil) {
        guard tracksContentReads, processingNamespace == 0,
              let key = markerKey(id: id, peer: peer, account: processingHistoryAccount, namespace: 0) else { return }
        if contentReadStates[key] == nil {
            if contentReadOrder.count >= 4000 { contentReadStates.removeValue(forKey: contentReadOrder.removeFirst()) }
            contentReadOrder.append(key)
        }
        var state = contentReadStates[key] ?? ContentReadState(peer: peer)
        state.peer = peer
        if let mention = mention { state.mention = mention }
        state.reaction = reaction == nil && state.reaction == true ? true : reaction
        if let disappearingMedia = disappearingMedia { state.disappearingMedia = disappearingMedia }
        contentReadStates[key] = state
    }

    private static func hasUnreadReactions(_ reactions: Api.MessageReactions?) -> Bool? {
        guard case let .messageReactions(data)? = reactions else { return false }
        if data.recentReactions?.contains(where: {
            switch $0 {
            case let .messagePeerReaction(reaction): return reaction.flags & (1 << 1) != 0
            case .other: return true
            }
        }) == true { return true }
        // A min constructor does not provide a complete unread state.
        return data.flags & 1 == 0 ? false : nil
    }

    private static func loadMarkers() {
        guard !markersLoaded else { return }
        markersLoaded = true
        for (storedKey, value) in UserDefaults.standard.dictionary(forKey: markerUdKey) ?? [:] {
            if let key = EditKey(storageKey: storedKey), let bits = value as? NSNumber {
                messageMarkers[key] = bits.intValue
            }
        }
        // Legacy accountless markers stay archived; their owner is unknown.
    }

    private static func markerKey(id: Int32, peer: Int64, account: String?, namespace: Int32) -> EditKey? {
        guard id != 0, let account = account else { return nil }
        let scope = (namespace == 0 || namespace == 5) && peer > -1_000_000_000_000 ? cloudScope : peer
        return EditKey(account: account, peer: scope, id: id, namespace: namespace)
    }

    private static func markerBits(id: Int32, peer: Int64, account: String?, namespace: Int32) -> Int {
        loadMarkers()
        guard let key = markerKey(id: id, peer: peer, account: account, namespace: namespace) else { return 0 }
        var bits = messageMarkers[key] ?? 0
        if namespace == 0 && peer <= -1_000_000_000_000 {
            let range = EditKey(account: key.account, peer: peer, id: 0)
            if id > 0 && Int(id) <= messageMarkers[range, default: 0] { bits |= deletedMarker }
        }
        return bits
    }

    private static func persistMarkers() {
        markersDirty = true
        if markerBatchDepth == 0 { flushMarkers() }
    }

    // Packet processing updates the in-memory map immediately and persists it once.
    private static func flushMarkers() {
        guard markersDirty else { return }
        markersDirty = false
        UserDefaults.standard.set(Dictionary(uniqueKeysWithValues: messageMarkers.map {
            ($0.key.storageKey, $0.value)
        }), forKey: markerUdKey)
    }

    private static func recordMarker(_ bit: Int, id: Int32, peer: Int64, account: String?, namespace: Int32) {
        loadMarkers()
        guard let key = markerKey(id: id, peer: peer, account: account, namespace: namespace),
              (messageMarkers[key, default: 0] & bit) == 0 else { return }
        messageMarkers[key, default: 0] |= bit
        persistMarkers()
    }

    @objc(addDeletedId:peer:account:messageNamespace:) static func addDeletedId(_ id: Int32, peer: Int64, account: String?, namespace: Int32 = 0) {
        processingLock.lock()
        defer { processingLock.unlock() }
        recordMarker(deletedMarker, id: id, peer: peer, account: account, namespace: namespace)
    }

    @objc static func loadPersistedIds() {
        processingLock.lock()
        loadMarkers()
        processingLock.unlock()
        editHistoryStore.load()
        installApiLogger()
    }

    // Last observed cloud messages can answer getMessages validation after a
    // reconnect. This does not intercept local Postbox transactions or decrypt
    // secret chats. Explicitly revoked snapshots are pinned; the ordinary
    // observation cache is bounded by arrival order, never by numeric id.
    private static let snapshotUdKey = "TGExtraObservedMessages"
    private static var snapshots = [EditKey: Data]()
    private static var snapshotOrder = [EditKey]()
    private static var snapshotsLoaded = false
    private static var snapshotWriteScheduled = false
    private static var snapshotGeneration: UInt64 = 0
    private static var requestedMessageIds: [Int32]?
    private static var requestedMessagePeer: Int64?

    private static func loadSnapshots() {
        guard !snapshotsLoaded else { return }
        snapshotsLoaded = true
        let saved = UserDefaults.standard.dictionary(forKey: snapshotUdKey) ?? [:]
        if let messages = saved["messages"] as? [String: Data] {
            for (raw, bytes) in messages {
                if let key = EditKey(storageKey: raw) { snapshots[key] = bytes }
            }
        }
        snapshotOrder = (saved["order"] as? [String] ?? []).compactMap(EditKey.init(storageKey:))
        var seen = Set<EditKey>()
        snapshotOrder = snapshotOrder.filter { snapshots[$0] != nil && seen.insert($0).inserted }
        snapshotOrder.append(contentsOf: snapshots.keys.filter { !seen.contains($0) }.sorted { $0.storageKey < $1.storageKey })
    }

    private static func writeSnapshots() {
        UserDefaults.standard.set([
            "messages": Dictionary(uniqueKeysWithValues: snapshots.map { ($0.key.storageKey, $0.value) }),
            "order": snapshotOrder.map { $0.storageKey }
        ], forKey: snapshotUdKey)
    }

    private static func scheduleSnapshotWrite() {
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

    private static func decodedSnapshot(_ bytes: Data) -> Api.Message? {
        let reader = BufferReader(Buffer(data: bytes))
        guard let constructor = reader.readInt32(),
              let message = Api.parse(reader, signature: constructor) as? Api.Message,
              reader.offset == UInt(bytes.count) else { return nil }
        MessagePatches.prepareDecodedObjects(in: reader)
        return message
    }

    private static func cacheMessage(_ message: Api.Message) {
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
        let key = EditKey(account: account, peer: peer, id: id)
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

    private static func restoreValidatedMessages(_ messages: [Api.Message]) -> ([Api.Message], Bool) {
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
        // Persist newly pinned snapshots before the host can validate again.
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

    private static func validationRequest(_ payload: NSData?, function: Int32) -> (ids: [Int32], peer: Int64?)? {
        guard function == 1673946374 || function == -1383294429, let payload = payload else { return nil }
        let reader = BufferReader(Buffer(nsData: payload))
        guard reader.readInt32() == function else { return nil }
        var peer: Int64?
        if function == -1383294429 {
            guard let constructor = reader.readInt32(), let channel = Api.parse(reader, signature: constructor) as? Api.InputChannel else { return nil }
            switch channel {
            case let .inputChannel(data): peer = -(1_000_000_000_000 + data.channelId)
            case let .inputChannelFromMessage(data): peer = -(1_000_000_000_000 + data.channelId)
            default: return nil
            }
        }
        guard reader.readInt32() == 481674261, let count = reader.readInt32(), count >= 0,
              Int(count) <= (payload.length - Int(reader.offset)) / 4 else { return nil }
        var ids = [Int32]()
        for _ in 0..<count {
            guard let constructor = reader.readInt32(), let input = Api.parse(reader, signature: constructor) as? Api.InputMessage else { return nil }
            if case let .inputMessageID(data) = input { ids.append(data.id) }
        }
        guard reader.offset == UInt(payload.length) else { return nil }
        return (ids, peer)
    }

    // MARK: - Edit history

    private typealias EditKey = MessageKey
    private typealias RenderedMessage = RenderedMessageReader.RenderedMessage
    private static let editHistoryStore = MessageHistoryStore()

    private static var isAntiEditEnabled: Bool {
        return MessagePatches.Settings().keepEditHistory
    }

    /// Mirrors the tgextraDiag() macro in Logger.h. os_log with an explicit
    /// {public} annotation, because both NSLog and unannotated os_log redact
    /// string arguments to "<private>" before they reach the device syslog.
    private static let diagLog = OSLog(subsystem: "com.choco.tg", category: "diag")

    /// Swift-side master switch for diagnostic logging. Must be kept in step
    /// with TGEXTRA_DIAG in Logger.h, which a Swift file cannot see. Left on, the
    /// signature tracing below takes a queue hop for every message parsed.
    private static let diagEnabled = false

    private static func diag(_ message: String) {
        guard diagEnabled else { return }
        os_log("[TGExtraDiag] %{public}@", log: diagLog, type: .default, message)
    }

    /// Reports each distinct TL constructor reaching the rewriter, once each and
    /// capped, so a device log shows what actually flows through without
    /// drowning in per-message noise. Diagnostic only.
    private static var seenSignatures = Set<Int32>()
    private static let signatureQueue = DispatchQueue(label: "com.tgextra.diagSignatures")

    private static func diagSignature(_ signature: Int32) {
        guard diagEnabled else { return }
        signatureQueue.sync {
            guard seenSignatures.count < 60, seenSignatures.insert(signature).inserted else { return }
            diag(String(format: "tl-in 0x%08X", UInt32(bitPattern: signature)))
        }
    }

    /// Routes the generated API layer's own "type constructor not found"
    /// complaints to the device log. That logger ships as a no-op, so a schema
    /// that has fallen behind the server fails silently: the container returns
    /// nil and every feature downstream simply never runs.
    ///
    /// Deduplicated — one unknown constructor inside a frequently received
    /// container would otherwise repeat without end.
    private static var loggedApiMessages = Set<String>()

    private static func installApiLogger() {
        guard diagEnabled else { return }
        setTelegramApiLogger { message in
            signatureQueue.sync {
                guard loggedApiMessages.count < 60,
                      loggedApiMessages.insert(message).inserted else { return }
                diag("api-layer: \(message)")
            }
        }
    }

    private static var unparsedSignatures = Set<Int32>()

    private static func diagUnparsed(_ signature: Int32) {
        guard diagEnabled else { return }
        signatureQueue.sync {
            guard unparsedSignatures.count < 40, unparsedSignatures.insert(signature).inserted else { return }
            diag(String(format: "tl-UNPARSED 0x%08X", UInt32(bitPattern: signature)))
        }
    }

    /// Clears only TGExtra's message metadata, across all accounts. Serialize
    /// with network parsing and drain pending writes before removing storage.
    @objc static func clearMessageData() {
        processingLock.lock()
        defer { processingLock.unlock() }
        editHistoryStore.clear()
        snapshotsLoaded = true
        snapshots.removeAll()
        snapshotOrder.removeAll()
        snapshotGeneration &+= 1
        snapshotWriteScheduled = false
        UserDefaults.standard.removeObject(forKey: snapshotUdKey)
        markersLoaded = true
        messageMarkers.removeAll()
        markersDirty = false
        contentReadStates.removeAll()
        contentReadOrder.removeAll()
        for key in [markerUdKey, "TGExtraDeletedMsgIds", "TGExtraSelfDestructingMsgIds", "TGExtraAutoDeleteMsgIds"] {
            UserDefaults.standard.removeObject(forKey: key)
        }
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: NSNotification.Name("TGExtraMessageDataCleared"), object: nil)
        }
    }

    /// Returns true when another text or content revision was appended. The date is
    /// a high-water mark even when a newer edit changes only formatting: a late
    /// response with an older text must not roll the history back afterwards.
    private static func recordText(_ text: String, forId id: Int32, peer: Int64,
                                   editDate: Int32?, allowUndatedEdit: Bool = false, content: [String: Data] = [:]) -> Bool {
        guard id != 0, peer != 0, let account = processingHistoryAccount else { return false }
        let key = EditKey(account: account, peer: peer, id: id, namespace: processingNamespace)
        return editHistoryStore.record(text, key: key, editDate: editDate, allowUndatedEdit: allowUndatedEdit, content: content)
    }

    /// Old archives did not record direction. Remove a message's saved versions
    /// as soon as either the network or the rendered item identifies it as ours.
    private static func discardOwnEditHistory(id: Int32, peer: Int64, account: String?, namespace: Int32) {
        guard let account = account else { return }
        let key = EditKey(account: account, peer: peer, id: id, namespace: namespace)
        let removed = editHistoryStore.discard(key)
        if removed { notifyMessageEdited(key) }
    }

    private static func isOwnAuthor(_ author: Api.Peer?, account: String?) -> Bool {
        guard let account = account, case let .peerUser(data)? = author,
              let ownId = PeerInfoStore.ownUserId(for: account) else { return false }
        return data.userId == ownId.int64Value
    }

    /// The conversation a message belongs to, as one number.
    ///
    /// Bot-API encoding: users stay positive, basic groups go negative, and
    /// channels are pushed past the group range, so the three id namespaces
    /// cannot collide with one another.
    private static func peerKey(_ peer: Api.Peer) -> Int64 {
        switch peer {
        case let .peerUser(data): return data.userId
        case let .peerChat(data): return -data.chatId
        case let .peerChannel(data): return -(1_000_000_000_000 + data.channelId)
        case .other: return 0
        }
    }

    /// An unresolved account must never see a different account's history.
    @objc(editHistoryForId:peer:account:messageNamespace:) static func editHistory(forId id: NSNumber, peer: NSNumber?, account: String?, namespace: NSNumber? = nil) -> [String]? {
        guard let account = account, let peer = peer, peer.int64Value != 0 else { return nil }
        let key = EditKey(account: account, peer: peer.int64Value, id: id.int32Value, namespace: namespace?.int32Value ?? 0)
        return editHistoryStore.versions(for: key)
    }

    @objc(editRevisionDetailsForId:peer:account:messageNamespace:) static func editRevisionDetails(forId id: NSNumber, peer: NSNumber?, account: String?, namespace: NSNumber?) -> [[String: Any]]? {
        guard let account = account, let peer = peer else { return nil }
        let key = EditKey(account: account, peer: peer.int64Value, id: id.int32Value, namespace: namespace?.int32Value ?? 0)
        return editHistoryStore.details(for: key)
    }

    private static func revisionContent(entities: [Api.MessageEntity]?, media: Api.MessageMedia?, rich: Api.RichMessage?) -> [String: Data] {
        let entityBuffer = Buffer()
        for entity in entities ?? [] { entity.serialize(entityBuffer, true) }
        var content = ["entities": entityBuffer.makeData(), "mediaIdentity": Data(), "rich": Data()]
        if let media = media {
            content["media"] = serializeBoxed(media) as Data
            let identity: String
            switch media {
            case let .messageMediaPhoto(data):
                switch data.photo {
                case let .photo(data)?: identity = "photo:\(data.id)"
                case let .photoEmpty(data)?: identity = "photo:\(data.id)"
                default: identity = "photo"
                }
            case let .messageMediaDocument(data):
                switch data.document {
                case let .document(data)?: identity = "document:\(data.id)"
                case let .documentEmpty(data)?: identity = "document:\(data.id)"
                default: identity = "document"
                }
            case .messageMediaPoll, .messageMediaGeoLive, .messageMediaWebPage:
                // Dynamic poll results, live location and webpage refreshes are
                // not edits. Track their type without recording every refresh.
                identity = media.descriptionFields().0
            default:
                identity = ""
            }
            content["mediaIdentity"] = identity.isEmpty ? content["media"] : Data(identity.utf8)
        }
        if let rich = rich { content["rich"] = serializeBoxed(rich) as Data }
        return content
    }

    /// Extract actual text blocks, not URLs, file references or debug dumps.
    private static func richText(_ value: Any, depth: Int = 0) -> String {
        guard depth < 48 else { return "" }
        let value = (value as? TLRecord).map(Api.view) ?? value
        if let message = value as? Api.RichMessage, case let .richMessage(data) = message {
            return data.blocks.map { richText($0, depth: depth + 1) }.joined(separator: "\n")
        }
        if let text = value as? Api.RichText {
            switch text {
            case let .textPlain(data): return data.text
            case let .textCustomEmoji(data): return data.alt
            case let .textMath(data): return data.source
            case let .textDiff(data): return richText(data.text, depth: depth + 1)
            default: break
            }
        }
        if let texts = value as? [Api.RichText] { return texts.map { richText($0, depth: depth + 1) }.joined() }
        if let record = Api.record(value), let descriptor = record.descriptor {
            let pieces = descriptor.fields.compactMap { field in
                record[field.name].map { richText(Api.exposedValue($0), depth: depth + 1) }
            }.filter { !$0.isEmpty }
            return pieces.joined(separator: record.typeName == "RichMessage" ? "\n" : "")
        }
        let mirror = Mirror(reflecting: value)
        let pieces = mirror.children.map { richText($0.value, depth: depth + 1) }.filter { !$0.isEmpty }
        return pieces.joined(separator: value is Api.RichMessage || mirror.displayStyle == .collection ? "\n" : "")
    }

    // Compact text updates have no full Message object; record their incoming originals too.
    private static func recordShortFormOriginal(id: Int32, text: String, peer: Int64, entities: [Api.MessageEntity]?, outgoing: Bool) {
        if outgoing {
            discardOwnEditHistory(id: id, peer: peer, account: processingHistoryAccount, namespace: processingNamespace)
            return
        }
        guard packetSettings.keepEditHistory else { return }
        guard id != 0 else { return }
        diag("anti-edit RECORD id=\(id) peer=\(peer) \(text.count) chars")
        _ = recordText(text, forId: id, peer: peer, editDate: nil, content: revisionContent(entities: entities, media: nil, rich: nil))
    }

    // Record incoming revisions without changing the text Telegram displays.
    private static func trackMessageVersions(_ apiMsg: Api.Message, allowUndatedEdit: Bool = false) {
        guard case let .message(data) = apiMsg else { return }
        guard data.id != 0 else { return }

        let peer = peerKey(data.peerId)
        if data.flags & (1 << 1) != 0 || isOwnAuthor(data.fromId, account: processingHistoryAccount) {
            discardOwnEditHistory(id: data.id, peer: peer, account: processingHistoryAccount, namespace: processingNamespace)
            return
        }
        guard packetSettings.keepEditHistory else { return }
        let text = data.richMessage.map { richText($0) }.flatMap { $0.isEmpty ? nil : $0 } ?? data.message
        let content = revisionContent(entities: data.entities, media: data.media, rich: data.richMessage)
        guard recordText(text, forId: data.id, peer: peer, editDate: data.editDate,
                         allowUndatedEdit: allowUndatedEdit, content: content),
              let account = processingHistoryAccount else { return }
        diag("anti-edit VERSION id=\(data.id) peer=\(peer) account=\(account)")

        notifyMessageEdited(EditKey(account: account, peer: peer, id: data.id, namespace: processingNamespace))
    }

    /// Applied to every batch of loaded messages. Records only; the batch is
    /// handed back untouched, so this never marks the response as modified.
    private static func trackVersions(in msgs: [Api.Message]) {
        msgs.forEach { trackMessageVersions($0) }
    }

    // Recover validation gaps, record revisions and apply message/chat policies together.
    private static func patchMessageBatch(_ msgs: [Api.Message], chats: [Api.Chat])
            -> (messages: [Api.Message], chats: [Api.Chat], changed: Bool) {
        let (messages, restored) = restoreValidatedMessages(msgs)
        messages.forEach(cacheMessage)
        trackVersions(in: messages)

        let (newChats, changedChats) = stripNoForwardsFromChats(chats)

        var changedTTL = false
        let final = messages.map { msg -> Api.Message in
            let (stripped, didStrip) = stripTTLMessage(msg)
            if didStrip { changedTTL = true }
            return stripped
        }
        return (final, newChats, restored || changedChats || changedTTL)
    }

    @objc static func getMessageId(from item: Any) -> NSNumber? {
        return RenderedMessageReader.renderedMessages(from: item).first.map { NSNumber(value: $0.id) }
    }

    @objc static func getMessageIdFromNode(_ node: Any) -> NSNumber? {
        return RenderedMessageReader.renderedMessagesFromNode(node).first.map { NSNumber(value: $0.id) }
    }

    @objc static func getMessagePeerKeyFromNode(_ node: Any) -> NSNumber? {
        return RenderedMessageReader.renderedMessagesFromNode(node).first.map { NSNumber(value: $0.peer) }
    }

    @objc static func getMessageNamespaceFromNode(_ node: Any) -> NSNumber? {
        return RenderedMessageReader.renderedMessagesFromNode(node).first.map { NSNumber(value: $0.namespace) }
    }

    /// TGExtra-internal bridge. One read supplies every component of identity.
    /// Observations use explicit keys and never change the network parser's scope.
    @objc(messageStateFromNode:observe:) static func messageState(from node: Any, observe: Bool) -> [String: Any]? {
        guard let item = HostValueReader.storedField("item", in: node) else { return nil }
        let messages = RenderedMessageReader.renderedMessages(from: item)
        guard let first = messages.first, let account = HostAccountReader.account(in: item, depth: 0) else { return nil }
        if observe {
            for message in messages {
                recordRenderedMessage(message, account: account)
            }
        }
        return ["id": NSNumber(value: first.id), "peer": NSNumber(value: first.peer),
                "namespace": NSNumber(value: first.namespace), "account": account]
    }

    @objc static func hasAdMessageFromNode(_ node: Any) -> Bool {
        return RenderedMessageReader.renderedMessagesFromNode(node).contains { message in
            let attributes = HostValueReader.storedField("attributes", in: message.value) as? [Any] ?? []
            return attributes.contains { String(reflecting: type(of: $0)).split(separator: ".").last == "AdMessageAttribute" }
        }
    }

    private struct EntityValue: Encodable {
        let value: Encodable
        func encode(to encoder: Encoder) throws { try value.encode(to: encoder) }
    }

    /// MessageTextEntity is a Codable value in Telegram 13.0. Encode that
    /// stored value, then normalize its documented fields to our wire format.
    /// Unknown entity kinds make entities unknown, rather than an empty list.
    private static func storedEntities(_ values: [Any]) -> Data? {
        let buffer = Buffer()
        for value in values {
            guard let value = value as? Encodable,
                  let data = try? JSONEncoder().encode(EntityValue(value: value)),
                  let fields = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let kind = fields["_rawValue"] as? NSNumber,
                  let start = fields["start"] as? NSNumber, let end = fields["end"] as? NSNumber,
                  let offset = Int32(exactly: start.int64Value),
                  let endOffset = Int32(exactly: end.int64Value), offset >= 0, endOffset >= offset,
                  let length = Int32(exactly: Int64(endOffset) - Int64(offset)) else { return nil }
            let entity: Api.MessageEntity
            switch kind.intValue {
            case 1: entity = .messageEntityMention(.init(offset: offset, length: length))
            case 2: entity = .messageEntityHashtag(.init(offset: offset, length: length))
            case 3: entity = .messageEntityBotCommand(.init(offset: offset, length: length))
            case 4: entity = .messageEntityUrl(.init(offset: offset, length: length))
            case 5: entity = .messageEntityEmail(.init(offset: offset, length: length))
            case 6: entity = .messageEntityBold(.init(offset: offset, length: length))
            case 7: entity = .messageEntityItalic(.init(offset: offset, length: length))
            case 8: entity = .messageEntityCode(.init(offset: offset, length: length))
            case 9: entity = .messageEntityPre(.init(offset: offset, length: length, language: fields["language"] as? String ?? ""))
            case 10:
                guard let url = fields["url"] as? String else { return nil }
                entity = .messageEntityTextUrl(.init(offset: offset, length: length, url: url))
            case 11:
                guard let peer = fields["peerId"] as? NSNumber else { return nil }
                entity = .messageEntityMentionName(.init(offset: offset, length: length, userId: peer.int64Value))
            case 12: entity = .messageEntityPhone(.init(offset: offset, length: length))
            case 13: entity = .messageEntityStrike(.init(offset: offset, length: length))
            case 14:
                guard let collapsed = fields["cl"] as? Bool else { return nil }
                entity = .messageEntityBlockquote(.init(flags: collapsed ? 1 : 0, offset: offset, length: length))
            case 15: entity = .messageEntityUnderline(.init(offset: offset, length: length))
            case 16: entity = .messageEntityBankCard(.init(offset: offset, length: length))
            case 17: entity = .messageEntitySpoiler(.init(offset: offset, length: length))
            case 18:
                guard let id = fields["f"] as? NSNumber else { return nil }
                entity = .messageEntityCustomEmoji(.init(offset: offset, length: length, documentId: id.int64Value))
            default: return nil
            }
            entity.serialize(buffer, true)
        }
        return buffer.makeData()
    }

    private static func storedMediaIdentity(_ media: [Any]) -> Data? {
        guard !media.isEmpty else { return Data() }
        // A wire message has one primary attachment. Extra local media (for
        // example an unsupported wrapper) must not masquerade as its absence.
        guard media.count == 1, let value = media.first else { return nil }
        if let image = HostValueReader.storedField("imageId", in: value),
           let id = HostValueReader.storedField("id", in: image).flatMap({ HostValueReader.rawNumber($0) }) {
            return Data("photo:\(id)".utf8)
        }
        if let file = HostValueReader.storedField("fileId", in: value),
           let id = HostValueReader.storedField("id", in: file).flatMap({ HostValueReader.rawNumber($0) }) {
            return Data("document:\(id)".utf8)
        }
        return nil
    }

    private static func recordRenderedMessage(_ message: RenderedMessage, account: String) {
        // Postbox MessageFlags.Incoming is bit 2 (wire Message.out is bit 1).
        guard let flags = HostValueReader.storedField("flags", in: message.value).flatMap({ HostValueReader.rawNumber($0) }) else { return }
        if flags & (1 << 2) == 0 {
            discardOwnEditHistory(id: message.id, peer: message.peer, account: account, namespace: message.namespace)
            return
        }
        guard isAntiEditEnabled else { return }
        guard let text = HostValueReader.storedField("text", in: message.value) as? String else { return }
        var editDate: Int32?
        var content = [String: Data]()
        if let attributes = HostValueReader.storedField("attributes", in: message.value) as? [Any] {
            // Attributes are stored, unlike Message.editedTime / item.message.
            var entities: [Any]? = []
            for attribute in attributes {
                let name = String(reflecting: type(of: attribute)).split(separator: ".").last
                if name == "EditedMessageAttribute" {
                    guard let date = HostValueReader.storedField("date", in: attribute).flatMap({ HostValueReader.rawNumber($0) }),
                          let parsedDate = Int32(exactly: date) else { return }
                    editDate = parsedDate
                }
                if name == "TextEntitiesMessageAttribute" {
                    entities = HostValueReader.storedField("entities", in: attribute) as? [Any]
                }
            }
            if let entities = entities { content["entities"] = storedEntities(entities) }
        }
        if let media = HostValueReader.storedField("media", in: message.value) as? [Any] {
            content["mediaIdentity"] = storedMediaIdentity(media)
        }
        let key = EditKey(account: account, peer: message.peer, id: message.id, namespace: message.namespace)
        if editHistoryStore.record(text, key: key, editDate: editDate, content: content, localSnapshot: true) {
            notifyMessageEdited(key)
        }
    }

    private static func notifyMessageEdited(_ key: EditKey) {
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: NSNotification.Name("TGExtraMessageEditedRealtime"),
                object: nil, userInfo: ["ids": [NSNumber(value: key.id)], "account": key.account,
                                       "peer": NSNumber(value: key.peer), "namespace": NSNumber(value: key.namespace)])
        }
    }

    /// Walk only the node -> item -> context -> account chain, never the
    /// global shared context or the account currently selected in another UI.
    @objc static func getHistoryAccountFromNode(_ node: Any) -> String? {
        return HostAccountReader.account(in: node, depth: 0)
    }

    /// Keep parsing until the requesting account's own id has been learned.
    private static var isOwnIdKnown: Bool {
        guard let account = processingHistoryAccount else { return true }
        return PeerInfoStore.ownUserId(for: account) != nil
    }

    /// Read the users vector through host metadata, including containers for
    /// which the tweak has no typed view.
    private static func noteUsersAnywhere(_ result: Any) {
        guard let record = Api.record(result) else { return }
        if let values = record["users"] as? [TLRecord] {
            let users = values.compactMap(Api.User.init)
            PeerInfoStore.observe(users, account: processingHistoryAccount)
        } else if let user = Api.User(record) {
            PeerInfoStore.observe([user], account: processingHistoryAccount)
        }
    }

    @objc(isDeleted:peer:account:messageNamespace:) static func isDeleted(_ msgId: NSNumber, peer: NSNumber?, account: String?, namespace: NSNumber? = nil) -> Bool {
        guard let peer = peer, peer.int64Value != 0 else { return false }
        processingLock.lock()
        defer { processingLock.unlock() }
        return markerBits(id: msgId.int32Value, peer: peer.int64Value, account: account,
                          namespace: namespace?.int32Value ?? 0) & deletedMarker != 0
    }

    @objc(isMessageSelfDestructing:peer:account:messageNamespace:) static func isMessageSelfDestructing(_ msgId: NSNumber, peer: NSNumber?, account: String?, namespace: NSNumber? = nil) -> Bool {
        guard let peer = peer else { return false }
        processingLock.lock()
        defer { processingLock.unlock() }
        return markerBits(id: msgId.int32Value, peer: peer.int64Value, account: account,
                          namespace: namespace?.int32Value ?? 0) & disappearingMarker != 0
    }

    /// Content reads also acknowledge mentions, reactions and playable media.
    /// Filter each category independently; one message ID is acknowledged atomically.
    @objc(readMessageContentsPolicy:account:) static func readMessageContentsPolicy(_ payload: NSData, account: String?) -> [String: NSData]? {
        guard payload.length >= 4 else { return nil }
        var function: Int32 = 0
        payload.getBytes(&function, length: 4)
        function = Int32(littleEndian: function)
        guard function == 916930423 || function == -357180360 else { return nil }
        let settings = MessagePatches.Settings(snapshot: true)
        guard settings.filtersContentReceipts else { return nil }
        let reader = BufferReader(Buffer(nsData: payload))
        _ = reader.readInt32()
        var peer = cloudScope
        if function == -357180360 {
            guard let constructor = reader.readInt32(),
                  let channel = Api.parse(reader, signature: constructor) as? Api.InputChannel else { return nil }
            let channelId: Int64
            switch channel {
            case let .inputChannel(data): channelId = data.channelId
            case let .inputChannelFromMessage(data): channelId = data.channelId
            default: return nil
            }
            guard channelId > 0, channelId <= Int64.max - 1_000_000_000_000 else { return nil }
            peer = -(1_000_000_000_000 + channelId)
        }
        let prefixLength = Int(reader.offset)
        guard reader.readInt32() == 481674261, let count = reader.readInt32(), count > 0,
              payload.length - Int(reader.offset) == Int(count) * 4 else { return nil }
        var ids = [Int32]()
        for _ in 0..<count {
            guard let id = reader.readInt32() else { return nil }
            ids.append(id)
        }
        processingLock.lock()
        let allowed = ids.filter {
            guard let key = markerKey(id: $0, peer: peer, account: account, namespace: 0) else { return false }
            let state = contentReadStates[key]
            let marked = settings.preventMediaSelfDestruct && markerBits(id: $0, peer: peer, account: account, namespace: 0) & disappearingMarker != 0
            return settings.allowsContentReceipt(disappearing: marked ? true : state?.disappearingMedia,
                mention: state?.mention, reaction: state?.reaction, classified: state != nil,
                ghostException: state.map { TGExtraIsGhostException($0.peer) } ?? false)
        }
        processingLock.unlock()
        guard allowed.count != ids.count else { return nil }
        if allowed.isEmpty {
            let response = Buffer()
            if function == -357180360 {
                response.appendInt32(Int32(bitPattern: 0x997275b5)) // boolTrue
            } else {
                response.appendInt32(Int32(bitPattern: 0x84d19185)) // messages.affectedMessages
                response.appendInt32(0)
                response.appendInt32(0)
            }
            return ["response": response.makeData() as NSData]
        }
        let filtered = Buffer(data: payload.subdata(with: NSRange(location: 0, length: prefixLength)))
        filtered.appendInt32(481674261)
        filtered.appendInt32(Int32(allowed.count))
        for id in allowed { filtered.appendInt32(id) }
        return ["payload": filtered.makeData() as NSData]
    }

    private static func recordTimedId(_ id: Int32, scope: Int64, disappearing: Bool) {
        recordMarker(disappearing ? disappearingMarker : autoDeleteMarker,
                     id: id, peer: scope, account: processingHistoryAccount, namespace: processingNamespace)
    }

    private static func deletionScope(_ peer: Api.Peer) -> Int64 {
        return peerKey(peer)
    }

    private static func stripTTLMedia(_ media: Api.MessageMedia, messageId: Int32, scope: Int64) -> Bool {
        guard MessagePatches.removeMediaTimer(from: media.record, settings: packetSettings) else { return false }
        recordTimedId(messageId, scope: scope, disappearing: true)
        return true
    }

    private static func stripNoForwards(_ chat: Api.Chat) -> (Api.Chat, Bool) {
        return (chat, MessagePatches.removeForwardingProtection(from: chat.record, settings: packetSettings))
    }

    private static func stripNoForwardsFromChats(_ chats: [Api.Chat]) -> ([Api.Chat], Bool) {
        var modified = false
        let newChats = chats.map { chat -> Api.Chat in
            let (stripped, changed) = stripNoForwards(chat)
            if changed {
                modified = true
            }
            return stripped
        }
        return (newChats, modified)
    }

    private static func stripNoForwardsFromFullChat(_ chatFull: Api.ChatFull) -> (Api.ChatFull, Bool) {
        // Copy protection is carried by Chat flags, not ChatFull.
        return (chatFull, false)
    }

    private static func stripTTLMessage(_ apiMsg: Api.Message) -> (Api.Message, Bool) {
        if case let .messageService(data) = apiMsg {
            noteContentReadState(id: data.id, peer: peerKey(data.peerId), mention: false,
                                 reaction: hasUnreadReactions(data.reactions), disappearingMedia: false)
            guard data.ttlPeriod != nil else { return (apiMsg, false) }
            recordTimedId(data.id, scope: deletionScope(data.peerId), disappearing: false)
            return (apiMsg, MessagePatches.removeAutoDeleteTimer(from: apiMsg.record, settings: packetSettings))
        }
        guard case let .message(data) = apiMsg else { return (apiMsg, false) }
        let scope = deletionScope(data.peerId)
        let disappearingMedia: Bool
        switch data.media {
        case let .messageMediaPhoto(media)?: disappearingMedia = media.ttlSeconds != nil
        case let .messageMediaDocument(media)?: disappearingMedia = media.ttlSeconds != nil
        default: disappearingMedia = false
        }
        noteContentReadState(id: data.id, peer: scope,
                             mention: data.flags & (1 << 4) != 0 && data.flags & (1 << 5) != 0,
                             reaction: hasUnreadReactions(data.reactions), disappearingMedia: disappearingMedia)
        let autoDelete = data.ttlPeriod != nil
        if autoDelete { recordTimedId(data.id, scope: scope, disappearing: false) }
        let before = apiMsg.record.changes.count
        let mediaChanged = data.media.map { stripTTLMedia($0, messageId: data.id, scope: scope) } ?? false
        let disappearing = markerBits(id: data.id, peer: scope, account: processingHistoryAccount, namespace: processingNamespace) & disappearingMarker != 0
        MessagePatches.removeAutoDeleteTimer(from: apiMsg.record, settings: packetSettings)
        MessagePatches.markDisappearingMessage(apiMsg, observedDisappearing: disappearing, settings: packetSettings)
        MessagePatches.removeForwardingProtection(from: apiMsg.record, settings: packetSettings)
        return (apiMsg, mediaChanged || before != apiMsg.record.changes.count)
    }

    private static func stripTTLUpdates(_ updates: [Api.Update]) -> ([Api.Update], Bool) {
        var modified = false
        let result = updates.map { update -> Api.Update in
            let (stripped, changed) = stripTTLUpdate(update)
            if changed {
                modified = true
            }
            return stripped
        }
        return (result, modified)
    }

    private static func stripTTLUpdate(_ update: Api.Update) -> (Api.Update, Bool) {
        let (rewritten, changed) = rewriteTTLUpdate(update)
        if changed { rewritten.record.retainUnwrittenFields(from: update.record) }
        return (rewritten, changed)
    }

    private static func rewriteTTLUpdate(_ update: Api.Update) -> (Api.Update, Bool) {
        switch update {
        case let .updateMessageReactions(data):
            noteContentReadState(id: data.msgId, peer: peerKey(data.peer), reaction: hasUnreadReactions(data.reactions))
            return (update, false)
        case let .updateNewMessage(data):
            cacheMessage(data.message)
            trackMessageVersions(data.message)
            let (strippedMsg, changed) = stripTTLMessage(data.message)
            if !changed {
                return (update, false)
            }
            return (.updateNewMessage(Api.Update.Cons_updateNewMessage(message: strippedMsg, pts: data.pts, ptsCount: data.ptsCount)), true)
        case let .updateNewChannelMessage(data):
            cacheMessage(data.message)
            trackMessageVersions(data.message)
            let (strippedMsg, changed) = stripTTLMessage(data.message)
            if !changed {
                return (update, false)
            }
            return (.updateNewChannelMessage(Api.Update.Cons_updateNewChannelMessage(message: strippedMsg, pts: data.pts, ptsCount: data.ptsCount)), true)
        // Edits are recorded and then passed through untouched. The reader sees
        // the edit as Telegram intended; the pencil badge is what surfaces the
        // versions that came before it.
        case let .updateEditMessage(data):
            cacheMessage(data.message)
            // Logged before the flag check: silence here otherwise cannot be
            // told apart from "the update never arrived".
            diag("updateEditMessage seen, antiEdit=\(packetSettings.keepEditHistory)")
            trackMessageVersions(data.message, allowUndatedEdit: true)
            let (message, changed) = stripTTLMessage(data.message)
            return (.updateEditMessage(.init(message: message, pts: data.pts, ptsCount: data.ptsCount)), changed)
        case let .updateEditChannelMessage(data):
            cacheMessage(data.message)
            diag("updateEditChannelMessage seen, antiEdit=\(packetSettings.keepEditHistory)")
            trackMessageVersions(data.message, allowUndatedEdit: true)
            let (message, changed) = stripTTLMessage(data.message)
            return (.updateEditChannelMessage(.init(message: message, pts: data.pts, ptsCount: data.ptsCount)), changed)
        case let .updateNewScheduledMessage(data):
            return withNamespace(3) {
                trackMessageVersions(data.message, allowUndatedEdit: true)
                let (message, changed) = stripTTLMessage(data.message)
                return (.updateNewScheduledMessage(.init(message: message)), changed)
            }
        case let .updateQuickReplyMessage(data):
            return withNamespace(5) {
                trackMessageVersions(data.message, allowUndatedEdit: true)
                let (message, changed) = stripTTLMessage(data.message)
                return (.updateQuickReplyMessage(.init(message: message)), changed)
            }
        case let .updateDeleteScheduledMessages(data):
            // Sending a scheduled message removes it from the queue normally.
            guard data.sentMessages == nil else { return (update, false) }
            return withNamespace(3) {
                guard let kept = neutralizeDeletions(data.messages, peer: peerKey(data.peer)) else { return (update, false) }
                MessagePatches.replaceDeletionIds(in: update.record, keeping: kept, settings: packetSettings)
                return (update, true)
            }
        case let .updateDeleteQuickReplyMessages(data):
            return withNamespace(5) {
                guard let kept = neutralizeDeletions(data.messages, peer: cloudScope) else { return (update, false) }
                MessagePatches.replaceDeletionIds(in: update.record, keeping: kept, settings: packetSettings)
                return (update, true)
            }
        case let .updateNewEphemeralMessage(data):
            let changed = patchEphemeralMessage(data.message, isEdit: false)
            return (update, changed)
        case let .updateEditEphemeralMessage(data):
            let changed = patchEphemeralMessage(data.message, isEdit: true)
            return (update, changed)
        case let .updateDeleteEphemeralMessages(data):
            var ids = data.ids
            // The host removes both local and anchored messages for these ids.
            for namespace: Int32 in [7, 8] {
                let kept = withNamespace(namespace) { neutralizeDeletions(data.ids, peer: peerKey(data.peer)) ?? data.ids }
                ids = zip(ids, kept).map { $0 == 0 || $1 == 0 ? 0 : $0 }
            }
            let changed = MessagePatches.replaceDeletionIds(in: update.record, keeping: ids, settings: packetSettings)
            return (update, changed)
        case let .updateChannelAvailableMessages(data):
            guard let noDeletion = MessagePatches.suppressChannelHistoryPruning(update, settings: packetSettings) else { return (update, false) }
            if let account = processingHistoryAccount, data.availableMinId > 0 {
                loadMarkers()
                let peer = -(1_000_000_000_000 + data.channelId)
                let key = EditKey(account: account, peer: peer, id: 0)
                messageMarkers[key] = max(messageMarkers[key, default: 0], Int(data.availableMinId))
                persistMarkers()
                loadSnapshots()
                if !snapshots.isEmpty { writeSnapshots() }
                let maxId = data.availableMinId
                DispatchQueue.main.async {
                    NotificationCenter.default.post(name: NSNotification.Name("TGExtraMessageDeletedRealtime"), object: nil,
                        userInfo: ["maxId": NSNumber(value: maxId), "account": account,
                                   "peer": NSNumber(value: peer), "namespace": NSNumber(value: 0)])
                }
            }
            // This update carries no pts. An empty zero-pts deletion is a no-op
            // for the host and preserves the surrounding packet's counters.
            return (noDeletion, true)
        case let .updateDeleteMessages(data):
            guard let kept = neutralizeDeletions(data.messages, peer: cloudScope) else { return (update, false) }
            MessagePatches.replaceDeletionIds(in: update.record, keeping: kept, settings: packetSettings)
            return (update, true)
        case let .updateDeleteChannelMessages(data):
            let channelPeer = -(1_000_000_000_000 + data.channelId)
            guard let kept = neutralizeDeletions(data.messages, peer: channelPeer) else { return (update, false) }
            MessagePatches.replaceDeletionIds(in: update.record, keeping: kept, settings: packetSettings)
            return (update, true)
        default:
            return (update, false)
        }
    }

    private static func patchEphemeralMessage(_ message: Api.EphemeralMessage, isEdit: Bool) -> Bool {
        guard case let .ephemeralMessage(data) = message else { return false }
        guard let peer = data.peerId else {
            guard let media = data.media else { return false }
            return stripTTLMedia(media, messageId: 0, scope: 0)
        }
        let namespace: Int32 = data.flags & (1 << 5) != 0 ? 9 : (data.anchorMsgId == nil ? 7 : 8)
        return withNamespace(namespace) {
            let own = isOwnAuthor(data.fromId, account: processingHistoryAccount)
            if own {
                discardOwnEditHistory(id: data.id, peer: peerKey(peer), account: processingHistoryAccount, namespace: namespace)
            }
            if packetSettings.keepEditHistory && isOwnIdKnown && !own {
                let text = data.richMessage.map { richText($0) }.flatMap { $0.isEmpty ? nil : $0 } ?? data.message
                if recordText(text, forId: data.id, peer: peerKey(peer), editDate: nil, allowUndatedEdit: isEdit,
                              content: revisionContent(entities: data.entities, media: data.media, rich: data.richMessage)),
                   let account = processingHistoryAccount {
                    let id = data.id
                    let peerId = peerKey(peer)
                    DispatchQueue.main.async {
                        NotificationCenter.default.post(name: NSNotification.Name("TGExtraMessageEditedRealtime"), object: nil,
                            userInfo: ["ids": [NSNumber(value: id)], "peer": NSNumber(value: peerId),
                                       "account": account, "namespace": NSNumber(value: namespace)])
                    }
                }
            }
            return data.media.map { stripTTLMedia($0, messageId: data.id, scope: peerKey(peer)) } ?? false
        }
    }

    // Zero only protected IDs, preserving vector length and server synchronization counters.
    private static func neutralizeDeletions(_ ids: [Int32], peer: Int64) -> [Int32]? {
        let settings = packetSettings
        guard settings.protectsAnyDeletions else { return nil }
        let kept = ids.map { id -> Int32 in
            guard id != 0 else { return 0 }
            let bits = settings.keepDeletedMessages ? 0 : markerBits(id: id, peer: peer, account: processingHistoryAccount, namespace: processingNamespace)
            let protected = settings.protectsDeletion(disappearing: bits & disappearingMarker != 0,
                                                     autoDelete: bits & autoDeleteMarker != 0)
            return protected ? 0 : id
        }
        let live = zip(ids, kept).compactMap { original, replacement in
            original != 0 && replacement == 0 ? original : nil
        }
        live.forEach { addDeletedId($0, peer: peer, account: processingHistoryAccount, namespace: processingNamespace) }
        guard kept != ids else { return nil }
        loadSnapshots()
        if !snapshots.isEmpty { writeSnapshots() }

        if let account = processingHistoryAccount {
            let saved = live.map { NSNumber(value: $0) }
            let namespace = processingNamespace
            DispatchQueue.main.async {
                NotificationCenter.default.post(
                    name: NSNotification.Name("TGExtraMessageDeletedRealtime"), object: nil,
                    userInfo: ["ids": saved, "account": account, "peer": NSNumber(value: peer),
                               "namespace": NSNumber(value: namespace)])
            }
        }
        diag("anti-revoke: neutralised \(live.count) deletion(s) in the parsed path")
        return kept
    }

    private static let processingLock = NSRecursiveLock()

    /// Accept an opaque tail only when a peer constructor is actually unknown.
    /// Malformed known peers and vector headers must not commit partial data.
    private static func hasUnknownPeer(_ reader: BufferReader, length: Int,
                                       usersFirst: Bool, suffixBytes: Int) -> Bool {
        guard length - Int(reader.offset) >= 16 + suffixBytes else { return false }
        let peerOrder: [Bool] = [usersFirst, !usersFirst]
        for (index, isUsers) in peerOrder.enumerated() {
            let minimumSuffix = suffixBytes + (index == 0 ? 8 : 0)
            guard reader.readInt32() == 481674261,
                  let count = reader.readInt32(), count >= 0,
                  length - Int(reader.offset) >= minimumSuffix,
                  Int(count) <= (length - Int(reader.offset) - minimumSuffix) / 4 else { return false }
            for _ in 0..<count {
                guard let constructor = reader.readInt32() else { return false }
                if !Api.isKnownConstructor(constructor) { return true }
                guard let peer = Api.parse(reader, signature: constructor),
                      isUsers ? peer is Api.User : peer is Api.Chat else { return false }
            }
        }
        return false
    }

    /// History and difference replies carry messages before their peer vectors.
    /// Read that known prefix without reserializing an unknown peer's bytes.
    private static func patchHistoryWithOpaquePeers(_ data: NSData, signature: Int32) -> NSData? {
        let reader = BufferReader(Buffer(nsData: data))
        reader.skip(4)

        func object<T>(_ type: T.Type) -> T? {
            guard let constructor = reader.readInt32() else { return nil }
            return Api.parse(reader, signature: constructor) as? T
        }
        func vector<T>(_ type: T.Type) -> [T]? {
            guard reader.readInt32() == 481674261,
                  let count = reader.readInt32(), count >= 0,
                  Int(count) <= (data.length - Int(reader.offset)) / 4 else { return nil }
            var values = [T]()
            for _ in 0..<count {
                guard let value = object(type) else { return nil }
                values.append(value)
            }
            return values
        }

        var flags: Int32 = 0
        var hasTopics = false
        var hasUpdates = false
        var hasEncrypted = false
        var suffixBytes = 0
        switch signature {
        case 494135274: // messages.messages
            hasTopics = true
        case -948520370, 1595959062: // channelMessages, messagesSlice
            guard let value = reader.readInt32(), reader.readInt32() != nil else { return nil }
            flags = value
            if signature == -948520370 {
                guard reader.readInt32() != nil else { return nil } // count (after pts)
            } else if flags & (1 << 0) != 0 {
                guard reader.readInt32() != nil else { return nil } // next_rate
            }
            if flags & (1 << 2) != 0 {
                guard reader.readInt32() != nil else { return nil }
            }
            if signature == 1595959062 && flags & (1 << 3) != 0 {
                guard object(Api.SearchPostsFlood.self) != nil else { return nil }
            }
            hasTopics = true
        case 364538944, 1910543603, 863093588: // dialogs, dialogsSlice, peerDialogs
            if signature == 1910543603 {
                guard reader.readInt32() != nil else { return nil }
            }
            guard vector(Api.Dialog.self) != nil else { return nil }
            if signature == 863093588 { suffixBytes = 24 } // updates.State
        case -1506535550: // discussionMessage
            guard let value = reader.readInt32() else { return nil }
            flags = value
        case 543450958: // channelDifference
            guard let value = reader.readInt32(), reader.readInt32() != nil else { return nil }
            if value & (1 << 1) != 0 {
                guard reader.readInt32() != nil else { return nil }
            }
            hasUpdates = true
        case -1531132162: // channelDifferenceTooLong
            guard let value = reader.readInt32() else { return nil }
            if value & (1 << 1) != 0 {
                guard reader.readInt32() != nil else { return nil }
            }
            guard object(Api.Dialog.self) != nil else { return nil }
        case 16030880, -1459938943: // difference, differenceSlice
            hasEncrypted = true
            hasUpdates = true
            suffixBytes = 24
        default:
            return nil
        }

        let messageStart = Int(reader.offset)
        guard let messages = vector(Api.Message.self) else { return nil }
        let messageEnd = Int(reader.offset)
        if hasTopics {
            guard vector(Api.ForumTopic.self) != nil else { return nil }
        }
        if hasEncrypted {
            guard vector(Api.EncryptedMessage.self) != nil else { return nil }
        }
        var updates = [Api.Update]()
        let updateStart = Int(reader.offset)
        var updateEnd = updateStart
        if hasUpdates {
            guard let values = vector(Api.Update.self) else { return nil }
            updates = values
            updateEnd = Int(reader.offset)
        }
        if signature == -1506535550 {
            for bit in 0...2 where flags & (1 << bit) != 0 {
                guard reader.readInt32() != nil else { return nil }
            }
            guard reader.readInt32() != nil else { return nil } // unread_count
        }
        guard hasUnknownPeer(reader, length: data.length, usersFirst: false,
                             suffixBytes: suffixBytes) else { return nil }
        MessagePatches.prepareDecodedObjects(in: reader)
        let batch = patchMessageBatch(messages, chats: [])
        let (patchedUpdates, changedUpdates) = stripTTLUpdates(updates)
        guard MessagePatches.shouldReserialize(changed: batch.changed || changedUpdates, settings: packetSettings) else {
            return reader.dataApplyingPatches()
        }
        func boxedVector(_ values: [Any]) -> Data? {
            let buffer = Buffer()
            buffer.appendInt32(481674261)
            buffer.appendInt32(Int32(values.count))
            for value in values { Api.serializeObject(value, buffer: buffer, boxed: true) }
            return buffer.makeValidData()
        }
        var replacements = [(Range<Int>, Data)]()
        guard let encodedMessages = boxedVector(batch.messages) else { return nil }
        replacements.append((messageStart..<messageEnd, encodedMessages))
        if hasUpdates {
            guard let encodedUpdates = boxedVector(patchedUpdates) else { return nil }
            replacements.append((updateStart..<updateEnd, encodedUpdates))
        }
        return reader.dataApplyingPatches(replacing: replacements)
    }

    /// A newer User or Chat constructor must not disable protection for the
    /// updates that precede it. Keep unknown peer bytes and the synchronization
    /// trailer intact while applying content edits to known peers.
    private static func patchUpdateVector(_ data: NSData, signature: Int32) -> NSData? {
        guard signature == 1957577280 || signature == 1918567619 else { return nil }
        let reader = BufferReader(Buffer(nsData: data))
        reader.skip(4)
        guard reader.readInt32() == 481674261,
              let count = reader.readInt32(), count >= 0,
              Int(count) <= (data.length - 12) / 4 else { return nil }

        var updates = [(update: Api.Update, start: Int, length: Int)]()
        for _ in 0..<count {
            let start = Int(reader.offset)
            guard let constructor = reader.readInt32(),
                  let update = Api.parse(reader, signature: constructor) as? Api.Update else {
                // An unknown update has no length prefix. Do not scan its
                // contents for constructor-looking words or guess its end.
                return nil
            }
            updates.append((update, start, Int(reader.offset) - start))
        }
        let tail = Int(reader.offset)
        // Two peer vectors plus date/seq (and seq_start for combined updates).
        let minimumTail = signature == 1918567619 ? 28 : 24
        guard data.length - tail >= minimumTail else { return nil }

        // Only an unknown peer constructor justifies leaving the tail opaque.
        // Known constructors that fail to decode, bad vector framing and a
        // missing date/seq must not record updates from a rejected packet.
        guard hasUnknownPeer(reader, length: data.length, usersFirst: true,
                             suffixBytes: signature == 1918567619 ? 12 : 8) else { return nil }
        MessagePatches.prepareDecodedObjects(in: reader)

        var replacements = [(Range<Int>, Data)]()
        for entry in updates {
            let (patched, changed) = stripTTLUpdate(entry.update)
            if MessagePatches.shouldReserialize(changed: changed, settings: packetSettings) {
                let encoded = serializeBoxed(patched)
                guard encoded.length >= 4 else { return nil }
                replacements.append((entry.start..<entry.start + entry.length, encoded as Data))
            }
        }
        return reader.dataApplyingPatches(replacing: replacements)
    }

    // Protected by processingLock, including recursive parsing of containers.
    private static var processingHistoryAccount: String?
    // Accessed only under processingLock. All messages in a packet use one settings snapshot.
    private static var processingSettings: MessagePatches.Settings?
    private static var packetSettings: MessagePatches.Settings { processingSettings ?? .init() }
    private static var processingNamespace: Int32 = 0

    private static func withNamespace<T>(_ namespace: Int32, _ body: () -> T) -> T {
        let previous = processingNamespace
        processingNamespace = namespace
        defer { processingNamespace = previous }
        return body()
    }

    @objc static func stripAntiSelfDestruct(_ data: NSData, account: String?) -> NSData? {
        processingLock.lock()
        markerBatchDepth += 1
        let previousSettings = processingSettings
        processingSettings = previousSettings ?? MessagePatches.Settings(snapshot: true)
        if !tracksContentReads {
            // Updates received while tracking is off invalidate older metadata.
            contentReadStates.removeAll()
            contentReadOrder.removeAll()
        }
        let previousAccount = processingHistoryAccount
        processingHistoryAccount = account
        defer {
            processingHistoryAccount = previousAccount
            processingSettings = previousSettings
            markerBatchDepth -= 1
            if markerBatchDepth == 0 { flushMarkers() }
            processingLock.unlock()
        }
        guard let patched = patchResponse(data, depth: 0), patched.length >= 4 else { return nil }
        return patched
    }

    private static func patchContentSettings(_ config: Api.help.AppConfig) -> NSData? {
        guard MessagePatches.allowIOSContent(in: config) else { return nil }
        return serializeBoxed(config)
    }

    @objc static func rewriteAppConfigRequest(_ payload: NSData) -> NSData? {
        return MessagePatches.refreshContentConfigurationRequest(payload)
    }

    private static func patchResponse(_ data: NSData, depth: Int) -> NSData? {
        guard data.length >= 4, depth < 16 else { return nil }
        let settings = packetSettings

        // iOS content restrictions are always removed, independently of the
        // optional message/forwarding features and account-id discovery.
        let buffer = Buffer(data: data as Data)
        let reader = BufferReader(buffer)
        guard let signature = reader.readInt32() else { return nil }

        diagSignature(signature)

        if signature == 0x3072cfa1 {
            guard let compressed = parseBytes(reader), reader.offset == UInt(data.length),
                  let inner = decompressGzip(compressed.data, Int(compressed.size)) else { return nil }
            // MTProto accepts an unpacked object at this seam.
            return patchResponse(inner as NSData, depth: depth + 1)
        }
        if signature == 0x73f1f8dc { // msg_container
            guard let count = reader.readInt32(), count >= 0, Int(count) <= (data.length - 8) / 16 else { return nil }
            var messages = [(id: Int64, sequence: Int32, body: NSData)]()
            for _ in 0..<count {
                guard let id = reader.readInt64(), let sequence = reader.readInt32(),
                      let length = reader.readInt32(), length >= 4, length % 4 == 0,
                      let body = reader.readBuffer(Int(length)) else { return nil }
                messages.append((id, sequence, body.makeData() as NSData))
            }
            // Validate all framing before recording anything from a child.
            guard reader.offset == UInt(data.length) else { return nil }
            let outBuf = Buffer()
            outBuf.appendInt32(0x73f1f8dc)
            outBuf.appendInt32(count)

            var modifiedContainer = false
            for message in messages {
                var newBodyData = message.body
                if let stripped = patchResponse(newBodyData, depth: depth + 1) {
                    newBodyData = stripped
                    modifiedContainer = true
                }

                outBuf.appendInt64(message.id)
                outBuf.appendInt32(message.sequence)
                outBuf.appendInt32(Int32(newBodyData.length))
                outBuf.appendBytes(newBodyData.bytes, length: UInt(newBodyData.length))
            }

            return modifiedContainer ? (outBuf.makeData() as NSData) : nil
        }
        if signature == 481674261 {
            guard let users = Api.parseVector(reader, elementSignature: 0, elementType: Api.User.self),
                  reader.offset == UInt(data.length) else { return nil }
            MessagePatches.prepareDecodedObjects(in: reader)
            PeerInfoStore.observe(users, account: processingHistoryAccount)
            return reader.dataApplyingPatches()
        }
        if !settings.processesMessages, let descriptor = TLCodec.descriptor(signature),
           HostSchema.shared?.types[descriptor.typeIndex] != "help.AppConfig" {
            var users = [Api.User]()
            if TLCodec.scan(reader, descriptor: descriptor, users: &users), reader.offset == UInt(data.length) {
                MessagePatches.prepareDecodedObjects(in: reader)
                PeerInfoStore.observe(users, account: processingHistoryAccount)
                return reader.dataApplyingPatches()
            }
            // Preserve the opaque-peer fallback and discard any partial scan.
            reader.reset()
            _ = reader.readInt32()
        }
        // Do not reset the reader, because Api.parse(reader, signature:) expects the reader to be at offset 4
        guard let result = Api.parse(reader, signature: signature) else {
            // Unknown peer constructors can leave a known message/update
            // prefix usable without rewriting the opaque tail.
            diagUnparsed(signature)
            if let patched = patchHistoryWithOpaquePeers(data, signature: signature) { return patched }
            return patchUpdateVector(data, signature: signature)
        }

        guard reader.offset == UInt(data.length) else { return nil }
        MessagePatches.prepareDecodedObjects(in: reader)
        if let config = result as? Api.help.AppConfig {
            return patchContentSettings(config)
        }
        noteUsersAnywhere(result)
        guard settings.processesMessages || !isOwnIdKnown else {
            return reader.dataApplyingPatches()
        }

        if MessagePatches.patchPrivateCopyResponse(result, reader: reader, settings: settings) {
            return reader.dataApplyingPatches()
        }

        let (newResult, modified) = rewriteDecoded(result, settings: settings)
        if MessagePatches.shouldReserialize(changed: modified, settings: settings) {
            let outBuf = Buffer()
            Api.serializeObject(newResult, buffer: outBuf, boxed: true)
            guard outBuf.isValid else { return nil }
            return outBuf.makeData() as NSData
        }
        return reader.dataApplyingPatches()
    }

    private static func rewriteDecoded(_ result: Any, settings: MessagePatches.Settings) -> (Any, Bool) {
        var modified = false
        var newResult: Any = result

        if let updates = result as? Api.Updates {
            switch updates {
            case let .updates(data):
                let (stripped, anyStripped) = stripTTLUpdates(data.updates)
                let (newChats, anyChatsChanged) = stripNoForwardsFromChats(data.chats)
                if anyStripped || anyChatsChanged {
                    newResult = Api.Updates.updates(Api.Updates.Cons_updates(updates: stripped, users: data.users, chats: newChats, date: data.date, seq: data.seq))
                    modified = true
                }
            case let .updateShort(data):
                let (stripped, changed) = stripTTLUpdate(data.update)
                if changed {
                    newResult = Api.Updates.updateShort(Api.Updates.Cons_updateShort(update: stripped, date: data.date))
                    modified = true
                }
            case let .updateShortMessage(data):
                noteContentReadState(id: data.id, peer: data.userId,
                                     mention: data.flags & (1 << 4) != 0 && data.flags & (1 << 5) != 0,
                                     reaction: false, disappearingMedia: false)
                recordShortFormOriginal(id: data.id, text: data.message,
                                        peer: data.userId, entities: data.entities, outgoing: data.flags & (1 << 1) != 0)
                let before = updates.record.changes.count
                if data.ttlPeriod != nil { recordTimedId(data.id, scope: cloudScope, disappearing: false) }
                MessagePatches.removeAutoDeleteTimer(from: updates.record, settings: packetSettings)
                MessagePatches.removeForwardingProtection(from: updates.record, settings: packetSettings)
                modified = before != updates.record.changes.count
            case let .updateShortChatMessage(data):
                noteContentReadState(id: data.id, peer: -data.chatId,
                                     mention: data.flags & (1 << 4) != 0 && data.flags & (1 << 5) != 0,
                                     reaction: false, disappearingMedia: false)
                recordShortFormOriginal(id: data.id, text: data.message,
                                        peer: -data.chatId, entities: data.entities,
                                        outgoing: data.flags & (1 << 1) != 0 || isOwnAuthor(.peerUser(.init(userId: data.fromId)), account: processingHistoryAccount))
                let before = updates.record.changes.count
                if data.ttlPeriod != nil { recordTimedId(data.id, scope: cloudScope, disappearing: false) }
                MessagePatches.removeAutoDeleteTimer(from: updates.record, settings: packetSettings)
                MessagePatches.removeForwardingProtection(from: updates.record, settings: packetSettings)
                modified = before != updates.record.changes.count
            case let .updateShortSentMessage(data):
                let before = updates.record.changes.count
                if data.ttlPeriod != nil { recordTimedId(data.id, scope: cloudScope, disappearing: false) }
                MessagePatches.removeAutoDeleteTimer(from: updates.record, settings: packetSettings)
                MessagePatches.removeForwardingProtection(from: updates.record, settings: packetSettings)
                let mediaChanged = data.media.map { stripTTLMedia($0, messageId: data.id, scope: cloudScope) } ?? false
                modified = mediaChanged || before != updates.record.changes.count
            case let .updatesCombined(data):
                let (stripped, anyStripped) = stripTTLUpdates(data.updates)
                let (newChats, anyChatsChanged) = stripNoForwardsFromChats(data.chats)
                if anyStripped || anyChatsChanged {
                    newResult = Api.Updates.updatesCombined(Api.Updates.Cons_updatesCombined(updates: stripped, users: data.users, chats: newChats, date: data.date, seqStart: data.seqStart, seq: data.seq))
                    modified = true
                }
            default:
                break
            }
        } else if let msgs = result as? Api.messages.Messages {
            switch msgs {
            case let .messages(data):
                let p = patchMessageBatch(data.messages, chats: data.chats)
                if p.changed {
                    newResult = Api.messages.Messages.messages(Api.messages.Messages.Cons_messages(messages: p.messages, topics: data.topics, chats: p.chats, users: data.users))
                    modified = true
                }
            case let .messagesSlice(data):
                let p = patchMessageBatch(data.messages, chats: data.chats)
                if p.changed {
                    newResult = Api.messages.Messages.messagesSlice(Api.messages.Messages.Cons_messagesSlice(flags: data.flags, count: data.count, nextRate: data.nextRate, offsetIdOffset: data.offsetIdOffset, searchFlood: data.searchFlood, messages: p.messages, topics: data.topics, chats: p.chats, users: data.users))
                    modified = true
                }
            case let .channelMessages(data):
                let p = patchMessageBatch(data.messages, chats: data.chats)
                if p.changed {
                    newResult = Api.messages.Messages.channelMessages(Api.messages.Messages.Cons_channelMessages(flags: data.flags, pts: data.pts, count: data.count, offsetIdOffset: data.offsetIdOffset, messages: p.messages, topics: data.topics, chats: p.chats, users: data.users))
                    modified = true
                }
            default:
                break
            }
        } else if let difference = result as? Api.updates.Difference {
            // Catch-up responses must apply the same policies as live updates.
            switch difference {
            case let .difference(data):
                let p = patchMessageBatch(data.newMessages, chats: data.chats)
                let (otherUpdates, changedUpdates) = stripTTLUpdates(data.otherUpdates)
                if p.changed || changedUpdates {
                    newResult = Api.updates.Difference.difference(Api.updates.Difference.Cons_difference(newMessages: p.messages, newEncryptedMessages: data.newEncryptedMessages, otherUpdates: otherUpdates, chats: p.chats, users: data.users, state: data.state))
                    modified = true
                }
            case let .differenceSlice(data):
                let p = patchMessageBatch(data.newMessages, chats: data.chats)
                let (otherUpdates, changedUpdates) = stripTTLUpdates(data.otherUpdates)
                if p.changed || changedUpdates {
                    newResult = Api.updates.Difference.differenceSlice(Api.updates.Difference.Cons_differenceSlice(newMessages: p.messages, newEncryptedMessages: data.newEncryptedMessages, otherUpdates: otherUpdates, chats: p.chats, users: data.users, intermediateState: data.intermediateState))
                    modified = true
                }
            default:
                break
            }
        } else if let difference = result as? Api.updates.ChannelDifference {
            // Channel differences also carry messages and deletions.
            switch difference {
            case let .channelDifference(data):
                let p = patchMessageBatch(data.newMessages, chats: data.chats)
                let (otherUpdates, changedUpdates) = stripTTLUpdates(data.otherUpdates)
                if p.changed || changedUpdates {
                    diag("channelDifference patched — \(p.messages.count) message(s), \(otherUpdates.count) update(s)")
                    newResult = Api.updates.ChannelDifference.channelDifference(Api.updates.ChannelDifference.Cons_channelDifference(flags: data.flags, pts: data.pts, timeout: data.timeout, newMessages: p.messages, otherUpdates: otherUpdates, chats: p.chats, users: data.users))
                    modified = true
                }
            case let .channelDifferenceTooLong(data):
                // Sent when the client has fallen too far behind to be caught up
                // update by update; it carries the tail of the history instead.
                let p = patchMessageBatch(data.messages, chats: data.chats)
                if p.changed {
                    diag("channelDifferenceTooLong patched — \(p.messages.count) message(s)")
                    newResult = Api.updates.ChannelDifference.channelDifferenceTooLong(Api.updates.ChannelDifference.Cons_channelDifferenceTooLong(flags: data.flags, timeout: data.timeout, dialog: data.dialog, messages: p.messages, chats: p.chats, users: data.users))
                    modified = true
                }
            default:
                break
            }
        } else if let chatFull = result as? Api.messages.ChatFull {
            switch chatFull {
            case let .chatFull(data):
                let (newFullChat, changedFull) = stripNoForwardsFromFullChat(data.fullChat)
                let (newChats, changedChats) = stripNoForwardsFromChats(data.chats)
                if changedFull || changedChats {
                    newResult = Api.messages.ChatFull.chatFull(Api.messages.ChatFull.Cons_chatFull(fullChat: newFullChat, chats: newChats, users: data.users))
                    modified = true
                }
            case .other: break
            }
        } else if let chats = result as? Api.messages.Chats {
            switch chats {
            case let .chats(data):
                let (newChats, changed) = stripNoForwardsFromChats(data.chats)
                if changed {
                    newResult = Api.messages.Chats.chats(Api.messages.Chats.Cons_chats(chats: newChats))
                    modified = true
                }
            case let .chatsSlice(data):
                let (newChats, changed) = stripNoForwardsFromChats(data.chats)
                if changed {
                    newResult = Api.messages.Chats.chatsSlice(Api.messages.Chats.Cons_chatsSlice(count: data.count, chats: newChats))
                    modified = true
                }
            case .other: break
            }
        } else if let update = result as? Api.Update {
            let (stripped, changed) = stripTTLUpdate(update)
            if changed {
                newResult = stripped
                modified = true
            }
        } else if let message = result as? Api.Message {
            cacheMessage(message)
            trackMessageVersions(message)
            let (stripped, changed) = stripTTLMessage(message)
            if changed {
                newResult = stripped
                modified = true
            }
        } else if let discussion = result as? Api.messages.DiscussionMessage {
            if case let .discussionMessage(data) = discussion {
                let p = patchMessageBatch(data.messages, chats: data.chats)
                if p.changed {
                    newResult = Api.messages.DiscussionMessage.discussionMessage(.init(flags: data.flags,
                        messages: p.messages, maxId: data.maxId, readInboxMaxId: data.readInboxMaxId,
                        readOutboxMaxId: data.readOutboxMaxId, unreadCount: data.unreadCount, chats: p.chats, users: data.users))
                    modified = true
                }
            }
        } else if let peerDialogs = result as? Api.messages.PeerDialogs {
            if case let .peerDialogs(data) = peerDialogs {
                let p = patchMessageBatch(data.messages, chats: data.chats)
                if p.changed {
                    newResult = Api.messages.PeerDialogs.peerDialogs(.init(dialogs: data.dialogs,
                        messages: p.messages, chats: p.chats, users: data.users, state: data.state))
                    modified = true
                }
            }
        } else if let welcome = result as? Api.ephemeral.WelcomeMessages {
            if case let .welcomeMessages(data) = welcome {
                for message in data.messages {
                    if patchEphemeralMessage(message, isEdit: true) { modified = true }
                }
            }
        } else if let dialogs = result as? Api.messages.Dialogs {
            switch dialogs {
            case let .dialogs(data):
                let p = patchMessageBatch(data.messages, chats: data.chats)
                if p.changed {
                    newResult = Api.messages.Dialogs.dialogs(.init(dialogs: data.dialogs, messages: p.messages, chats: p.chats, users: data.users))
                    modified = true
                }
            case let .dialogsSlice(data):
                let p = patchMessageBatch(data.messages, chats: data.chats)
                if p.changed {
                    newResult = Api.messages.Dialogs.dialogsSlice(.init(count: data.count, dialogs: data.dialogs, messages: p.messages, chats: p.chats, users: data.users))
                    modified = true
                }
            default: break
            }
        }

        if let original = Api.record(result), let replacement = Api.record(newResult), original !== replacement {
            replacement.retainUnwrittenFields(from: original)
        }
        return (newResult, modified)
    }

    static func patchNative(_ root: Any, account: String?, function: Int32, request: Data?) -> Any? {
        processingLock.lock()
        markerBatchDepth += 1
        let previousAccount = processingHistoryAccount
        let previousSettings = processingSettings
        let previousNamespace = processingNamespace
        let previousIds = requestedMessageIds
        let previousPeer = requestedMessagePeer
        processingHistoryAccount = account
        processingSettings = MessagePatches.Settings(snapshot: true)
        let settings = packetSettings
        switch function {
        case -183077365, -1111817116: processingNamespace = 3
        case -1801153085: processingNamespace = 5
        default: processingNamespace = 0
        }
        let validation = validationRequest(request as NSData?, function: function)
        requestedMessageIds = validation?.ids
        requestedMessagePeer = validation?.peer
        defer {
            processingHistoryAccount = previousAccount; processingSettings = previousSettings
            processingNamespace = previousNamespace; requestedMessageIds = previousIds; requestedMessagePeer = previousPeer
            markerBatchDepth -= 1
            if markerBatchDepth == 0 { flushMarkers() }
            processingLock.unlock()
        }
        if !settings.tracksContentReads { contentReadStates.removeAll(); contentReadOrder.removeAll() }
        let context = NativeTLContext()
        let nativeRoot = TGExtraNativeObject(object: root)
        let descriptor = nativeRoot.flatMap { HostSchema.shared?.constructors[Int32(bitPattern: $0.constructorId)] }
        let appConfig = descriptor.map { HostSchema.shared?.types[$0.typeIndex] == "help.AppConfig" } ?? false
        if !appConfig && !settings.protectsAnyDeletions && !settings.keepEditHistory && !settings.tracksContentReads {
            var mask = TGExtraNativeSettings()
            if settings.bypassForwarding { mask.insert(.bypassForwarding) }
            if settings.bypassPrivateCopy { mask.insert(.bypassPrivateCopy) }
            let users = TGExtraNativeApplyRoot(root, mask).compactMap { context.record($0 as AnyObject).flatMap(Api.User.init) }
            PeerInfoStore.observe(users, account: processingHistoryAccount)
            return root
        }
        context.reader.parsedRecords = TGExtraNativeObjects(root).compactMap { context.record($0 as AnyObject) }
        MessagePatches.prepareDecodedObjects(in: context.reader)
        if let values = root as? [Any] {
            let users = values.compactMap { context.record($0 as AnyObject).flatMap(Api.User.init) }
            PeerInfoStore.observe(users, account: processingHistoryAccount)
            _ = context.commit(nil, allChanges: false)
            return root
        }
        guard let record = context.record(root as AnyObject) else { return nil }
        let result = Api.view(record)
        if let config = result as? Api.help.AppConfig {
            let changed = MessagePatches.allowIOSContent(in: config)
            return context.commit(record, allChanges: changed)
        }
        noteUsersAnywhere(result)
        guard settings.processesMessages || !isOwnIdKnown else { return context.commit(record, allChanges: false) }
        if MessagePatches.patchPrivateCopyResponse(result, reader: context.reader, settings: settings) {
            return context.commit(record, allChanges: false)
        }
        let (rewritten, changed) = rewriteDecoded(result, settings: settings)
        let replacement = Api.record(rewritten)
        // Fieldless enum views do not carry a payload object. Reuse the
        // decoded backing object when its constructor was not replaced.
        let output = !changed && replacement?.constructorName == record.constructorName ? record : replacement
        return context.commit(output, allChanges: MessagePatches.shouldReserialize(changed: changed, settings: settings))
    }

    /// users.getFullUser, users.getUsers, contacts.resolveUsername — the three
    /// replies that carry a name for a peer you just opened.
    private static let peerLookupFunctions: Set<Int32> = [-1240508136, 227648840, 1918565308]

    /// Parses a reply purely to file the names in it.
    ///
    /// Also handles peer lookups independently of the optional message features.
    /// Names are learned even when there is no content restriction to rewrite.
    private static func harvestPeerNames(_ data: NSData) {
        let reader = BufferReader(Buffer(data: data as Data))
        guard let signature = reader.readInt32() else { return }

        // users.getUsers answers with a bare Vector<User>, which Api.parse has
        // no entry for — it only knows named constructors. Read the vector
        // directly instead of losing every name that arrives this way.
        if signature == 481674261 {
            guard let users = Api.parseVector(reader, elementSignature: 0,
                                              elementType: Api.User.self) else { return }
            PeerInfoStore.observe(users, account: processingHistoryAccount)
            return
        }

        guard let result = Api.parse(reader, signature: signature) else { return }
        noteUsersAnywhere(result)
    }

    @objc(handleResponse:functionID:account:requestPayload:) static func handleResponse(_ data: NSData, functionID: NSNumber, account: String?, requestPayload: NSData? = nil) -> NSData? {
        processingLock.lock()
        let previousAccount = processingHistoryAccount
        processingHistoryAccount = account
        defer {
            processingHistoryAccount = previousAccount
            processingLock.unlock()
        }
        let previousIds = requestedMessageIds
        let previousPeer = requestedMessagePeer
        let validation = validationRequest(requestPayload, function: functionID.int32Value)
        requestedMessageIds = validation?.ids
        requestedMessagePeer = validation?.peer
        defer {
            requestedMessageIds = previousIds
            requestedMessagePeer = previousPeer
        }
        if peerLookupFunctions.contains(functionID.int32Value) {
            harvestPeerNames(data)
        }
        // Returns patched data only if something was actually modified.
        // Returning nil means "no change" — caller uses original data as-is.
        let namespace: Int32
        switch functionID.int32Value {
        case -183077365, -1111817116: namespace = 3 // scheduled history / messages
        case -1801153085: namespace = 5 // quick replies
        default: namespace = 0
        }
        return withNamespace(namespace) { stripAntiSelfDestruct(data, account: account) }
    }
    @objc static func fakeUpdatesResponse() -> NSData {
        // Keep request privacy independent of schema discovery.
        let buffer = Buffer()
        buffer.appendInt32(1957577280) // updates
        for _ in 0..<3 {
            buffer.appendInt32(481674261)
            buffer.appendInt32(0)
        }
        buffer.appendInt32(Int32(Date().timeIntervalSince1970))
        buffer.appendInt32(0)
        return buffer.makeData() as NSData
    }

    static func serializeBoxed(_ obj: Any) -> NSData {
        let outBuf = Buffer()
        Api.serializeObject(obj, buffer: outBuf, boxed: true)
        return outBuf.makeData() as NSData
    }

    // MARK: - Video to Voice, wire side
    //
    // Telegram's `.file` path attaches nothing but a filename, so the extracted
    // audio arrives as a document. Turning it into a voice message means giving
    // the document a documentAttributeAudio with the voice flag, a duration and
    // a waveform, and the only place left to do that is the outgoing request.
    //
    // Everything here is keyed off the file name the extractor invented, so a
    // request that was not produced by Video to Voice is never touched.

    private struct VoiceUpload {
        let duration: Int32
        let waveform: Data?
    }

    private static let voiceQueue = DispatchQueue(label: "com.tgextra.voiceUploads",
                                                  attributes: .concurrent)
    private static var _voiceUploads = [String: VoiceUpload]()
    private static var _voiceOrder = [String]()

    @objc static func registerVoiceUpload(withFileName fileName: String,
                                          duration: Int,
                                          waveform: NSData?) {
        guard !fileName.isEmpty else { return }
        let entry = VoiceUpload(duration: Int32(max(1, duration)),
                                waveform: waveform as Data?)
        voiceQueue.async(flags: .barrier) {
            if _voiceUploads[fileName] == nil { _voiceOrder.append(fileName) }
            _voiceUploads[fileName] = entry
            // A send can be retried long after it was queued, so entries are
            // kept for a while rather than consumed on first use.
            while _voiceOrder.count > 32 {
                _voiceUploads.removeValue(forKey: _voiceOrder.removeFirst())
            }
        }
    }

    private static func voiceUpload(forFileName name: String) -> VoiceUpload? {
        var result: VoiceUpload?
        voiceQueue.sync { result = _voiceUploads[name] }
        return result
    }

    /// Packs 0…31 amplitudes into the five-bits-per-sample bitstream Telegram
    /// expects. Mirrors AudioWaveform.makeBitstream in the app.
    private static func packWaveform(_ bars: Data) -> Data {
        let count = bars.count
        guard count > 0 else { return Data() }
        let byteLength = (count * 5 + 7) / 8
        // Four bytes of slack: each sample is written with an unaligned 32-bit
        // OR, which can reach past the last byte on the final sample.
        var out = Data(count: byteLength + 4)
        out.withUnsafeMutableBytes { rawOut in
            guard let base = rawOut.baseAddress else { return }
            for i in 0 ..< count {
                let value = UInt32(bars[bars.startIndex + i] & 0x1f)
                let bitOffset = i * 5
                let pointer = base.advanced(by: bitOffset / 8)
                var current: UInt32 = 0
                memcpy(&current, pointer, 4)
                current |= value << UInt32(bitOffset % 8)
                memcpy(pointer, &current, 4)
            }
        }
        return out.prefix(byteLength)
    }

    /// documentAttributeAudio with voice set, plus the waveform when we have one.
    private static func voiceAttribute(_ upload: VoiceUpload) -> Api.DocumentAttribute {
        var flags: Int32 = 1 << 10          // voice
        var waveform: Buffer?
        if let bars = upload.waveform, !bars.isEmpty {
            flags |= 1 << 2                 // waveform present
            waveform = Buffer(data: packWaveform(bars))
        }
        return Api.DocumentAttribute.documentAttributeAudio(
            Api.DocumentAttribute.Cons_documentAttributeAudio(
                flags: flags, duration: upload.duration,
                title: nil, performer: nil, waveform: waveform))
    }

    /// Swaps the attributes of an upload that should go out as a voice message.
    /// Returns nil for anything else, which means "leave it alone".
    private static func voiceMedia(from media: Api.InputMedia) -> Api.InputMedia? {
        guard case let .inputMediaUploadedDocument(data) = media else { return nil }

        var fileName: String?
        for attribute in data.attributes {
            switch attribute {
            case let .documentAttributeFilename(nameData):
                fileName = nameData.fileName
            default:
                break
            }
        }

        var newAttributes: [Api.DocumentAttribute]?

        if let name = fileName, let upload = voiceUpload(forFileName: name) {
            // Video to Voice: we extracted this file ourselves, so we know both
            // how long it runs and what it looks like.
            diag("v2v wire: \(name) -> voice, \(upload.duration)s")
            newAttributes = [voiceAttribute(upload)]
        }

        guard let attributes = newAttributes else { return nil }

        guard MessagePatches.replaceVoiceAttributes(in: media.record, attributes: attributes, registeredUpload: true) else { return nil }
        return media
    }

    /// Reads one boxed object and throws the value away — used to step over the
    /// fields that sit before the media without having to know their shape.
    private static func skipBoxed(_ reader: BufferReader) -> Bool {
        guard let signature = reader.readInt32() else { return false }
        return Api.parse(reader, signature: signature) != nil
    }

    /// The album case: every item in the vector is offered to voiceMedia, and
    /// the whole vector is re-emitted only if at least one of them was ours.
    private static func rewriteMultiMedia(_ payload: Data, reader: BufferReader) -> NSData? {
        let vectorStart = Int(reader.offset)
        guard reader.readInt32() == 481674261 else { return nil }   // Vector
        guard let items = Api.parseVector(reader, elementSignature: 0,
                                          elementType: Api.InputSingleMedia.self) else { return nil }
        let vectorEnd = Int(reader.offset)

        var changed = false
        let rewritten: [Api.InputSingleMedia] = items.map { item in
            guard case let .inputSingleMedia(data) = item,
                  voiceMedia(from: data.media) != nil else { return item }
            changed = true
            return item
        }
        guard changed else { return nil }

        let vectorBuffer = Buffer()
        vectorBuffer.appendInt32(481674261)
        vectorBuffer.appendInt32(Int32(rewritten.count))
        for item in rewritten { item.serialize(vectorBuffer, true) }
        guard vectorBuffer.isValid else { return nil }

        var out = Data()
        out.append(payload.subdata(in: 0 ..< vectorStart))
        out.append(vectorBuffer.makeData())
        out.append(payload.subdata(in: vectorEnd ..< payload.count))
        return out as NSData
    }

    /// Rewrites the media inside an outgoing send request.
    ///
    /// Only the fields ahead of the media are decoded; everything after it is
    /// copied through byte for byte. That keeps the rewrite honest about what it
    /// understands — a constructor that changed shape after the media field
    /// cannot be corrupted by it.
    @objc static func rewriteVoiceUpload(_ data: NSData) -> NSData? {
        guard MessagePatches.Settings().videoToVoice else { return nil }

        let payload = data as Data
        let reader = BufferReader(Buffer(data: payload))
        guard let functionId = reader.readInt32() else { return nil }

        switch functionId {
        case 53536639:   // messages.sendMedia
            guard let flags = reader.readInt32() else { return nil }
            guard skipBoxed(reader) else { return nil }                  // peer
            if (Int(flags) & (1 << 0)) != 0 {
                guard skipBoxed(reader) else { return nil }              // reply_to
            }
        case 345405816:  // messages.uploadMedia
            guard let flags = reader.readInt32() else { return nil }
            if (Int(flags) & (1 << 0)) != 0 {
                guard parseString(reader) != nil else { return nil }     // business_connection_id
            }
            guard skipBoxed(reader) else { return nil }                  // peer
        case 469278068:  // messages.sendMultiMedia — several clips picked at once
            guard let flags = reader.readInt32() else { return nil }
            guard skipBoxed(reader) else { return nil }                  // peer
            if (Int(flags) & (1 << 0)) != 0 {
                guard skipBoxed(reader) else { return nil }              // reply_to
            }
            return rewriteMultiMedia(payload, reader: reader)
        default:
            return nil
        }

        let mediaStart = Int(reader.offset)
        guard let signature = reader.readInt32(), signature == 58495792 else { return nil }
        guard let media = Api.parse(reader, signature: signature) as? Api.InputMedia else { return nil }
        let mediaEnd = Int(reader.offset)
        guard let rewritten = voiceMedia(from: media) else { return nil }

        let mediaBuffer = Buffer()
        rewritten.serialize(mediaBuffer, true)
        guard mediaBuffer.isValid else { return nil }

        var out = Data()
        out.append(payload.subdata(in: 0 ..< mediaStart))
        out.append(mediaBuffer.makeData())
        out.append(payload.subdata(in: mediaEnd ..< payload.count))
        return out as NSData
    }
}
