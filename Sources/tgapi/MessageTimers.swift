import Foundation

extension TLParser {
    static func recordTimedId(_ id: Int32, scope: Int64, disappearing: Bool) {
        recordMarker(disappearing ? disappearingMarker : autoDeleteMarker,
                     id: id, peer: scope, account: processingHistoryAccount, namespace: processingNamespace)
    }

    static func deletionScope(_ peer: Api.Peer) -> Int64 {
        return peerKey(peer)
    }

    static func stripTTLMedia(_ media: Api.MessageMedia, messageId: Int32, scope: Int64) -> Bool {
        guard MessagePatches.removeMediaTimer(from: media.record, settings: packetSettings) else { return false }
        recordTimedId(messageId, scope: scope, disappearing: true)
        return true
    }

    static func stripNoForwards(_ chat: Api.Chat) -> (Api.Chat, Bool) {
        return (chat, MessagePatches.removeForwardingProtection(from: chat.record, settings: packetSettings))
    }

    static func stripNoForwardsFromChats(_ chats: [Api.Chat]) -> ([Api.Chat], Bool) {
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

    static func stripNoForwardsFromFullChat(_ chatFull: Api.ChatFull) -> (Api.ChatFull, Bool) {
        return (chatFull, false)
    }

    static func stripTTLMessage(_ apiMsg: Api.Message) -> (Api.Message, Bool) {
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

    static func patchMessageBatch(_ msgs: [Api.Message], chats: [Api.Chat])
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
}
