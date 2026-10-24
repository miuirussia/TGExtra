import Foundation
import TestSupport

func testReadContents() {
    let saved = defaults.dictionaryRepresentation()
    defer {
        TLParser.clearMessageData()
        for key in defaults.dictionaryRepresentation().keys { defaults.removeObject(forKey: key) }
        for (key, value) in saved { defaults.set(value, forKey: key) }
    }
    TLParser.clearMessageData()
    flags("TGExtraAntiSelfDestruct")
    defaults.set(true, forKey: "TGExtraGhostModeEnabled")
    defaults.set(true, forKey: "disableMessageReadReceipt")
    defaults.set(false, forKey: "disableReactionReadReceipt")
    defaults.set(false, forKey: "disableMentionReadReceipt")
    let channel = Api.InputChannel.inputChannel(.init(channelId: 77, accessHash: 123))
    let otherChannel = Api.InputChannel.inputChannel(.init(channelId: 78, accessHash: 456))
    let fromMessage = Api.InputChannel.inputChannelFromMessage(.init(
        peer: .inputPeerUser(.init(userId: 42, accessHash: 1)), msgId: 10, channelId: 77))
    func contents(_ ids: [Int32], channel: Api.InputChannel? = nil) -> NSData {
        if let channel = channel { return Api.functions.channels.readMessageContents(channel: channel, id: ids).1.makeData() as NSData }
        return Api.functions.messages.readMessageContents(id: ids).1.makeData() as NSData
    }
    func observe(_ id: Int32, peer: Api.Peer = .peerUser(.init(userId: 42)), account: String = testAccount) {
        let media = Api.MessageMedia.messageMediaPhoto(.init(flags: 5, photo: .photoEmpty(.init(id: 99)), ttlSeconds: 5, video: nil))
        _ = strip(serialized(message(id, peer: peer, media: media)), account: account)
    }
    observe(91001)
    observe(91001, peer: .peerChannel(.init(channelId: 77)))
    observe(91003, account: "account-2")
    // Chat auto-delete is independent of opening disappearing media.
    flags("TGExtraAntiSelfDestruct", "TGExtraAntiAutoDelete")
    _ = patch(message(91004, ttl: 60))

    func verify(_ payload: NSData, expected: NSData? = nil, blocked: Bool = false, account: String? = testAccount, channel: Bool = false) {
        let serverResponse = channel ? serialized(Api.Bool.boolTrue) : serialized(Api.messages.AffectedMessages.affectedMessages(.init(pts: 99, ptsCount: 1)))
        let fakeResponse = channel ? serialized(Api.Bool.boolTrue) : serialized(Api.messages.AffectedMessages.affectedMessages(.init(pts: 0, ptsCount: 0)))
        let mt = TGExtraTestReadContentsRequest(payload as Data, account) as! [String: NSData]
        check(mt["payload"] == (expected ?? payload), "MtProtoKit sends only permitted content IDs")
        check(mt["response"] == (blocked ? fakeResponse : nil), "Only fully suppressed content reads get synthetic replies")
        let rust = TGExtraTestRustReadContentsRequest(payload as Data, account, serverResponse as Data) as! [String: NSData]
        let nearest = Buffer(); nearest.appendInt32(0x1fb33026)
        check(rust["payload"] == (blocked ? nearest.makeData() as NSData : expected ?? payload), "Rust uses the same account-scoped content policy")
        check(rust["response"] == (blocked ? fakeResponse : serverResponse), "Rust preserves real synchronization counters for permitted reads")
    }
    for channelInput in [nil, channel, fromMessage] as [Api.InputChannel?] {
        verify(contents([91002, 91004], channel: channelInput), channel: channelInput != nil)
        verify(contents([91001], channel: channelInput), blocked: true, channel: channelInput != nil)
        verify(contents([91002, 91001, 91004, 91002], channel: channelInput),
               expected: contents([91002, 91004, 91002], channel: channelInput), channel: channelInput != nil)
    }
    verify(contents([91001]), account: "account-2")
    verify(contents([91003]))
    verify(contents([91001], channel: otherChannel), channel: true)
    verify(contents([91002]), blocked: true, account: nil)
    verify(contents([]))
    let valid = contents([91001])
    for length in 0..<valid.length {
        check(TLParser.readMessageContentsPolicy(valid.subdata(with: NSRange(location: 0, length: length)) as NSData, account: testAccount) == nil,
              "Truncated vectors are never rewritten")
    }
    let trailing = NSMutableData(data: valid as Data); trailing.append(Data([0]))
    check(TLParser.readMessageContentsPolicy(trailing, account: testAccount) == nil, "Trailing bytes are never silently dropped")
    let oversized = Buffer(); oversized.appendInt32(916930423); oversized.appendInt32(481674261); oversized.appendInt32(Int32.max)
    check(TLParser.readMessageContentsPolicy(oversized.makeData() as NSData, account: testAccount) == nil, "Invalid vector counts are bounded by the payload")

    let peer = Api.InputPeer.inputPeerUser(.init(userId: 42, accessHash: 1))
    let history = Api.functions.messages.readHistory(peer: peer, maxId: 91004).1.makeData() as NSData
    check(TGExtraFakeResponseForPayload(history as Data) != nil, "History read receipts remain hidden")
    for payload in [Api.functions.messages.readMentions(flags: 0, peer: peer, topMsgId: nil).1.makeData(),
                    Api.functions.messages.readReactions(flags: 0, peer: peer, topMsgId: nil, savedPeerId: nil).1.makeData()] {
        check(TGExtraFakeResponseForPayload(payload) == nil && TLParser.readMessageContentsPolicy(payload as NSData, account: testAccount) == nil,
              "Bulk mention and reaction reads remain independent of history receipts")
    }
    defaults.set(false, forKey: "TGExtraGhostModeEnabled")
    verify(contents([91001]), blocked: true)
    flags()
    verify(contents([91001]))
    verify(contents([91001], channel: channel), channel: true)

    // Exercise each privacy switch independently, with all other features off.
    let reaction = Api.Reaction.reactionEmoji(.init(emoticon: "👍"))
    func reactions(unread: Bool, minimal: Bool = false) -> Api.MessageReactions {
        .messageReactions(.init(flags: 2 | (minimal ? 1 : 0), results: [], recentReactions: [
            .messagePeerReaction(.init(flags: unread ? 2 : 1, peerId: .peerUser(.init(userId: 42)), date: 100, reaction: reaction))
        ], topReactors: nil))
    }
    func observeContent(_ id: Int32, mention: Bool = false, reaction: Bool = false,
                        account: String = testAccount, channel: Bool = false) {
        let value = message(id, peer: channel ? .peerChannel(.init(channelId: 77)) : .peerUser(.init(userId: 42)))
        let data = messageData(value)
        data.flags |= 1 << 5 // playable media alone must not count as a mention
        if mention { data.flags |= 1 << 4 }
        data.flags |= 1 << 20
        data.reactions = reactions(unread: reaction)
        _ = strip(serialized(value), account: account)
    }
    func verifyBulk(_ payload: Data, blocked: Bool) {
        let real = serialized(Api.messages.AffectedHistory.affectedHistory(.init(pts: 99, ptsCount: 1, offset: 0)))
        let fake = serialized(Api.messages.AffectedHistory.affectedHistory(.init(pts: 0, ptsCount: 0, offset: 0)))
        check(TGExtraFakeResponseForPayload(payload) == (blocked ? fake as Data : nil), "Bulk read toggles return the correct affectedHistory reply")
        let result = TGExtraTestRustReadContentsRequest(payload, testAccount, real as Data) as! [String: NSData]
        let nearest = Buffer(); nearest.appendInt32(0x1fb33026)
        check(result["payload"] == (blocked ? nearest.makeData() as NSData : payload as NSData), "Rust honors the selected bulk read toggle")
        check(result["response"] == (blocked ? fake : real), "Allowed bulk reads retain server counters")
    }
    let bulkMentions = Api.functions.messages.readMentions(flags: 1, peer: peer, topMsgId: 10).1.makeData()
    let bulkReactions = Api.functions.messages.readReactions(flags: 1, peer: peer, topMsgId: 10, savedPeerId: nil).1.makeData()
    defaults.set(true, forKey: "TGExtraGhostModeEnabled")
    for hideMessages in [false, true] {
        for hideMentions in [false, true] {
            for hideReactions in [false, true] {
                defaults.set(hideMessages, forKey: "disableMessageReadReceipt")
                defaults.set(hideMentions, forKey: "disableMentionReadReceipt")
                defaults.set(hideReactions, forKey: "disableReactionReadReceipt")
                for isChannel in [false, true] {
                    observeContent(92001, mention: true, channel: isChannel)
                    observeContent(92002, reaction: true, channel: isChannel)
                    observeContent(92003, channel: isChannel)
                    observeContent(92004, mention: true, reaction: true, channel: isChannel)
                    let input = isChannel ? channel : nil
                    verify(contents([92001], channel: input), blocked: hideMentions, channel: isChannel)
                    verify(contents([92002], channel: input), blocked: hideReactions, channel: isChannel)
                    verify(contents([92003], channel: input), channel: isChannel)
                    verify(contents([92004], channel: input), blocked: hideMentions || hideReactions, channel: isChannel)
                    let kept: [Int32] = (hideMentions ? [] : [92001]) + (hideReactions ? [] : [92002]) + [92003]
                    verify(contents([92001, 92002, 92003], channel: input), expected: contents(kept, channel: input), channel: isChannel)
                }
                check((TGExtraFakeResponseForPayload(history as Data) != nil) == hideMessages, "Content toggles never change the history toggle")
                verifyBulk(bulkMentions, blocked: hideMentions)
                verifyBulk(bulkReactions, blocked: hideReactions)
            }
        }
    }
    for payload in [bulkMentions, bulkReactions] {
        for length in 0..<payload.count {
            check(TGExtraFakeResponseForPayload(Data(payload.prefix(length))) == nil, "Truncated bulk read requests pass through")
        }
    }
    let savedReactions = Api.functions.messages.readReactions(flags: 3, peer: .inputPeerSelf, topMsgId: 10, savedPeerId: peer).1.makeData()
    verifyBulk(savedReactions, blocked: true)

    defaults.set(false, forKey: "disableMentionReadReceipt")
    for unread in [true, false] {
        _ = patch(Api.Update.updateMessageReactions(.init(flags: 0, peer: .peerUser(.init(userId: 42)), msgId: 92010,
            topMsgId: nil, savedPeerId: nil, reactions: reactions(unread: unread))))
        verify(contents([92010]), blocked: unread)
    }
    observeContent(92011)
    _ = patch(Api.Update.updateMessageReactions(.init(flags: 0, peer: .peerUser(.init(userId: 42)), msgId: 92011,
        topMsgId: nil, savedPeerId: nil, reactions: reactions(unread: false, minimal: true))))
    verify(contents([92011]), blocked: true)
    // An incomplete update cannot disprove an unread flag received later.
    _ = patch(Api.Update.updateMessageReactions(.init(flags: 0, peer: .peerUser(.init(userId: 42)), msgId: 92011,
        topMsgId: nil, savedPeerId: nil, reactions: reactions(unread: true))))
    _ = patch(Api.Update.updateMessageReactions(.init(flags: 0, peer: .peerUser(.init(userId: 42)), msgId: 92011,
        topMsgId: nil, savedPeerId: nil, reactions: reactions(unread: false, minimal: true))))
    verify(contents([92011]), blocked: true)
    observeContent(92003, account: "account-2")
    verify(contents([92003]), account: "account-2")
    verify(contents([92002]), blocked: true, account: "account-2") // unknown in this account
    verify(contents([92003], channel: otherChannel), blocked: true, channel: true)
    verify(contents([92003]), blocked: true, account: nil)

    defaults.set(true, forKey: "disableMentionReadReceipt")
    _ = patch(Api.Updates.updateShortMessage(.init(flags: 48, id: 92030, userId: 42, message: "Mention", pts: 1, ptsCount: 1,
        date: 100, fwdFrom: nil, viaBotId: nil, replyTo: nil, entities: nil, ttlPeriod: nil)))
    verify(contents([92030]), blocked: true)
    observeContent(92020)
    let scheduled = message(92020)
    messageData(scheduled).flags |= (1 << 4) | (1 << 5)
    _ = patch(Api.Update.updateNewScheduledMessage(.init(message: scheduled)))
    verify(contents([92020]))
    TGExtraTestSetGhostException(42, true)
    verify(contents([92001, 92002, 92004]))
    verifyBulk(bulkMentions, blocked: false)
    verifyBulk(bulkReactions, blocked: false)
    verify(contents([92001], channel: channel), blocked: true, channel: true)
    defaults.set(true, forKey: "TGExtraAntiSelfDestruct")
    verify(contents([91001]), blocked: true) // TTL protection overrides exceptions
    TGExtraTestSetGhostException(42, false)
    defaults.set(false, forKey: "TGExtraAntiSelfDestruct")
    defaults.set(false, forKey: "TGExtraGhostModeEnabled")
    verify(contents([92001, 92002, 92004]))
    verifyBulk(bulkMentions, blocked: false)
    verifyBulk(bulkReactions, blocked: false)
    defaults.set(true, forKey: "TGExtraGhostModeEnabled")
    defaults.set(false, forKey: "disableMentionReadReceipt")
    defaults.set(false, forKey: "disableReactionReadReceipt")
    _ = patch(message(92003))
    defaults.set(true, forKey: "disableReactionReadReceipt")
    verify(contents([92003]), blocked: true)
    observeContent(92003)
    verify(contents([92003]))
    TLParser.clearMessageData()
    verify(contents([92003]), blocked: true)
    print("PASS separate history/content reads, mixed TTL filtering, MtProtoKit/Rust parity and account/channel isolation")
}
