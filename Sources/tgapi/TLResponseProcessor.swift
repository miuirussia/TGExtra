import Foundation
import tgapiC

extension TLParser {
    // All packet state and policy calls share this recursive lock.
    static let processingLock = NSRecursiveLock()

    static var processingHistoryAccount: String?

    static var processingSettings: MessagePatches.Settings?

    static var packetSettings: MessagePatches.Settings { processingSettings ?? .init() }

    static var processingNamespace: Int32 = 0

    static var requestedMessageIds: [Int32]?

    static var requestedMessagePeer: Int64?

    static func withNamespace<T>(_ namespace: Int32, _ body: () -> T) -> T {
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

    static func patchContentSettings(_ config: Api.help.AppConfig) -> NSData? {
        guard MessagePatches.allowIOSContent(in: config) else { return nil }
        return serializeBoxed(config)
    }

    @objc static func rewriteAppConfigRequest(_ payload: NSData) -> NSData? {
        return MessagePatches.refreshContentConfigurationRequest(payload)
    }

    static func patchResponse(_ data: NSData, depth: Int) -> NSData? {
        guard data.length >= 4, depth < 16 else { return nil }
        let settings = packetSettings

        let buffer = Buffer(data: data as Data)
        let reader = BufferReader(buffer)
        guard let signature = reader.readInt32() else { return nil }

        diagSignature(signature)

        if signature == 0x3072cfa1 {
            guard let compressed = parseBytes(reader), reader.offset == UInt(data.length),
                  let inner = decompressGzip(compressed.data, Int(compressed.size)) else { return nil }
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
            reader.reset()
            _ = reader.readInt32()
        }
        guard let result = Api.parse(reader, signature: signature) else {
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
        case TLMethodID.messagesGetScheduledHistory, TLMethodID.messagesGetScheduledMessages: processingNamespace = 3
        case TLMethodID.messagesGetQuickReplyMessages: processingNamespace = 5
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
        let output = !changed && replacement?.constructorName == record.constructorName ? record : replacement
        return context.commit(output, allChanges: MessagePatches.shouldReserialize(changed: changed, settings: settings))
    }

    static let peerLookupFunctions: Set<Int32> = [TLMethodID.usersGetFullUser, TLMethodID.usersGetUsers, TLMethodID.contactsResolveUsername]

    static func harvestPeerNames(_ data: NSData) {
        let reader = BufferReader(Buffer(data: data as Data))
        guard let signature = reader.readInt32() else { return }

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
        let namespace: Int32
        switch functionID.int32Value {
        case TLMethodID.messagesGetScheduledHistory, TLMethodID.messagesGetScheduledMessages: namespace = 3 // scheduled history / messages
        case TLMethodID.messagesGetQuickReplyMessages: namespace = 5 // quick replies
        default: namespace = 0
        }
        return withNamespace(namespace) { stripAntiSelfDestruct(data, account: account) }
    }
}
