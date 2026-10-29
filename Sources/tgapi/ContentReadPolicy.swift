import Foundation
import tgapiC

extension TLParser {
    struct ContentReadState {
        var peer: Int64
        var mention: Bool?
        var reaction: Bool?
        var disappearingMedia: Bool?
    }

    // Access requires processingLock.
    static var contentReadStates = [MessageKey: ContentReadState]()

    static var contentReadOrder = [MessageKey]()

    static var tracksContentReads: Bool {
        return packetSettings.tracksContentReads
    }

    static func noteContentReadState(id: Int32, peer: Int64, mention: Bool? = nil, reaction: Bool?, disappearingMedia: Bool? = nil) {
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

    static func hasUnreadReactions(_ reactions: Api.MessageReactions?) -> Bool? {
        guard case let .messageReactions(data)? = reactions else { return false }
        if data.recentReactions?.contains(where: {
            switch $0 {
            case let .messagePeerReaction(reaction): return reaction.flags & (1 << 1) != 0
            case .other: return true
            }
        }) == true { return true }
        return data.flags & 1 == 0 ? false : nil
    }

    @objc(readMessageContentsPolicy:account:) static func readMessageContentsPolicy(_ payload: NSData, account: String?) -> [String: NSData]? {
        guard payload.length >= 4 else { return nil }
        var function: Int32 = 0
        payload.getBytes(&function, length: 4)
        function = Int32(littleEndian: function)
        guard function == TLMethodID.messagesReadContents || function == TLMethodID.channelsReadContents else { return nil }
        let settings = MessagePatches.Settings(snapshot: true)
        guard settings.filtersContentReceipts else { return nil }
        let reader = BufferReader(Buffer(nsData: payload))
        _ = reader.readInt32()
        var peer = cloudScope
        if function == TLMethodID.channelsReadContents {
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
            if function == TLMethodID.channelsReadContents {
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
}
