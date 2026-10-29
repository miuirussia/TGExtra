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
        guard let method = requestMethod(payload),
              method == .messagesReadContents || method == .channelsReadContents else { return nil }
        let settings = MessagePatches.Settings(snapshot: true)
        guard settings.filtersContentReceipts,
              let record = request(payload), let ids = record["id"] as? [Int32], !ids.isEmpty else { return nil }
        var peer = cloudScope
        if method == .channelsReadContents {
            guard let channel = record["channel"] as? TLRecord,
                  ["inputChannel", "inputChannelFromMessage"].contains(channel.constructorName),
                  let channelId = channel["channelId"] as? Int64,
                  channelId > 0, channelId <= Int64.max - 1_000_000_000_000 else { return nil }
            peer = -(1_000_000_000_000 + channelId)
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
            guard let response = emptyResponse(method: method,
                constructor: method == .channelsReadContents ? "boolTrue" : "affectedMessages") else { return nil }
            return ["response": response]
        }
        record["id"] = allowed
        guard let filtered = record.serializedData() else { return nil }
        return ["payload": filtered as NSData]
    }
}
