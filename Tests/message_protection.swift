import Foundation

func testMessageProtection() {
    struct PeerIdentifier { let namespace: Int32; let id: Int64 }
    struct MessageIdentifier { let peerId: PeerIdentifier; let namespace: Int32; let id: Int32 }
    struct NodeMessage { let id: MessageIdentifier }
    struct NodeItem { let message: NodeMessage }
    class Node { let item: NodeItem?; init(_ namespace: Int32) {
        item = NodeItem(message: NodeMessage(id: MessageIdentifier(peerId: PeerIdentifier(namespace: 2, id: 77), namespace: namespace, id: 10)))
    } }
    final class InheritedNode: Node {}
    for namespace: Int32 in [0, 3, 5, 7, 8, 9] {
        check(TLParser.getMessageNamespaceFromNode(InheritedNode(namespace))?.int32Value == namespace, "UI resolves MessageId.namespace through optional inherited items")
    }
    check(TLParser.getMessageNamespaceFromNode(NSObject()) == nil, "Unknown UI objects cannot borrow the cloud namespace")
    TLParser.clearMessageData()
    flags("TGExtraAntiAutoDelete")
    _ = strip(serialized(message(81001, ttl: 60)), account: "account-1")
    check(strip(serialized(deletion([81001])), account: "account-2") == nil, "Timers never protect another account's messages")
    check(strip(serialized(deletion([81001])), account: nil) == nil, "Unresolved accounts never borrow timer classifications")
    check(deletionIds(parsed(patch(deletion([81001]))!, as: Api.Update.self)) == [0], "The owning account retains timer protection")
    check(isDeleted(81001, peer: 42) && !isDeleted(81001, peer: 42, account: "account-2"), "Deletion markers are account-scoped")
    check(!isDeleted(81001, peer: 42, account: nil), "Unresolved UI accounts cannot read markers")
    TLParser.addDeletedId(81002, peer: 42, account: nil)
    check(!isDeleted(81002, peer: 42), "Unresolved network accounts cannot write markers")
    defaults.set(["81003": [NSNumber(value: 0)]], forKey: "TGExtraDeletedMsgIds")
    check(!isDeleted(81003, peer: 42), "Legacy accountless markers are not assigned implicitly")

    for isChannel in [false, true] {
        let id: Int32 = isChannel ? 81005 : 81004
        let peer: Api.Peer = isChannel ? .peerChannel(.init(channelId: 77)) : .peerUser(.init(userId: 42))
        _ = patch(message(id, peer: peer, ttl: 60))
        let revised = message(id, peer: peer, text: "Edited", ttl: 60, edit: 2000)
        let update: Api.Update = isChannel
            ? .updateEditChannelMessage(.init(message: revised, pts: 52, ptsCount: 1))
            : .updateEditMessage(.init(message: revised, pts: 52, ptsCount: 1))
        let result = parsed(patch(update)!, as: Api.Update.self)
        let resultMessage: Api.Message
        switch result {
        case let .updateEditMessage(data): resultMessage = data.message
        case let .updateEditChannelMessage(data): resultMessage = data.message
        default: fatalError("Expected edit")
        }
        check(messageData(resultMessage).ttlPeriod == nil, "Editing never reinstalls a local timer")
    }
    let timedService = Api.Message.messageService(.init(flags: 1 << 25, id: 81006, fromId: nil,
        peerId: .peerUser(.init(userId: 42)), savedPeerId: nil, replyTo: nil, date: 1234,
        action: .messageActionEmpty, reactions: nil, ttlPeriod: 60))
    guard case let .messageService(service) = parsed(patch(timedService)!, as: Api.Message.self) else { fatalError("Expected service") }
    check(service.ttlPeriod == nil, "Service messages lose auto-delete timers too")

    // Exercise every supported history/difference shape, including opaque tails.
    for (index, reply) in historyReplies.enumerated() {
        let value = reply.wrap([message(81100 + Int32(index), ttl: 60)], [])
        check(patch(value) != nil, "\(reply.name) strips timers")
        for user in [false, true] {
            let bytes = withOpaqueHistoryPeer(value, suffix: reply.suffix, user: user)
            check(strip(bytes) != nil, "\(reply.name) strips timers with an unknown peer")
        }
    }
    flags("TGExtraAntiSelfDestruct")
    let photo = Api.MessageMedia.messageMediaPhoto(.init(flags: 5, photo: .photoEmpty(.init(id: 99)), ttlSeconds: 5, video: nil))
    let sent = Api.Updates.updateShortSentMessage(.init(flags: 1 << 9, id: 81200, pts: 52, ptsCount: 1,
        date: 1234, media: photo, entities: nil, ttlPeriod: nil))
    guard case let .updateShortSentMessage(sentResult) = parsed(patch(sent)!, as: Api.Updates.self),
          case let .messageMediaPhoto(sentPhoto)? = sentResult.media else { fatalError("Expected sent photo") }
    check(sentPhoto.ttlSeconds == nil, "Short sent replies serialize media-only rewrites")

    flags("TGExtraAntiRevoke")
    let range = Api.Update.updateChannelAvailableMessages(.init(channelId: 77, availableMinId: 500))
    guard case let .updateDeleteMessages(noOp) = parsed(patch(range)!, as: Api.Update.self) else { fatalError("Expected no-op") }
    check(noOp.messages.isEmpty && noOp.pts == 0 && noOp.ptsCount == 0, "Range deletion becomes an inert update")
    check(isDeleted(499, peer: -1_000_000_000_077) && !isDeleted(501, peer: -1_000_000_000_077), "Range markers include only deleted ids")
    check(!isDeleted(499, peer: -1_000_000_000_078) && !isDeleted(499, peer: -1_000_000_000_077, account: "account-2"), "Range markers are isolated by channel and account")
    for reply in historyReplies where ["channelDifference", "difference", "differenceSlice"].contains(reply.name) {
        let value = reply.wrap([], [deletion([81201], channel: 77)])
        for user in [false, true] {
            check(strip(withOpaqueHistoryPeer(value, suffix: reply.suffix, user: user)) != nil, "Opaque \(reply.name) blocks deletions")
        }
    }

    flags("TGExtraAntiEdit", "TGExtraAntiRevoke")
    func deliverHistory(_ text: String, namespace: Int32, edit: Int32?) {
        let value = Api.messages.Messages.messages(.init(messages: [message(81300, text: text, edit: edit)], topics: [], chats: [], users: []))
        let function: NSNumber = namespace == 3 ? -183077365 : (namespace == 5 ? -1801153085 : 1143203525)
        _ = response(serialized(value), functionID: function)
    }
    for namespace: Int32 in [0, 3, 5] {
        deliverHistory("Original \(namespace)", namespace: namespace, edit: nil)
        deliverHistory("Edited \(namespace)", namespace: namespace, edit: 2000)
        check(history(forId: 81300, peer: 42, namespace: namespace) == ["Original \(namespace)", "Edited \(namespace)"], "Namespaces retain independent histories")
    }
    for (namespace, update) in [
        (Int32(3), Api.Update.updateNewScheduledMessage(.init(message: message(81300, text: "Scheduled update", edit: 2001)))),
        (Int32(5), Api.Update.updateQuickReplyMessage(.init(message: message(81300, text: "Quick update", edit: 2001))))
    ] {
        _ = patch(update)
        check(history(forId: 81300, peer: 42, namespace: namespace)?.count == 3, "Special live updates record revisions")
    }
    let scheduledDelete = Api.Update.updateDeleteScheduledMessages(.init(flags: 0, peer: .peerUser(.init(userId: 42)), messages: [81300], sentMessages: nil))
    check(patch(scheduledDelete) != nil && isDeleted(81300, peer: 42, namespace: 3), "Scheduled revocations stay in their namespace")
    check(!isDeleted(81300, peer: 42), "Scheduled revocations do not mark normal messages")
    let scheduledSent = Api.Update.updateDeleteScheduledMessages(.init(flags: 1, peer: .peerUser(.init(userId: 42)), messages: [81300], sentMessages: [81400]))
    check(patch(scheduledSent) == nil, "Sending removes a scheduled message from the queue normally")
    let quickDelete = Api.Update.updateDeleteQuickReplyMessages(.init(shortcutId: 1, messages: [81300]))
    check(patch(quickDelete) != nil && isDeleted(81300, peer: 42, namespace: 5), "Quick-reply revocations are isolated")

    func ephemeral(_ text: String, anchored: Bool = false) -> Api.EphemeralMessage {
        .ephemeralMessage(.init(flags: (1 << 9) | (anchored ? 1 << 11 : 0), id: 81301,
            fromId: .peerUser(.init(userId: 43)), peerId: .peerUser(.init(userId: 42)), receiverId: 42,
            topMsgId: nil, date: 1234, message: text, entities: nil, media: nil, replyMarkup: nil,
            replyTo: nil, richMessage: nil, chatInstance: nil, anchorMsgId: anchored ? 12 : nil))
    }
    for anchored in [false, true] {
        _ = patch(Api.Update.updateNewEphemeralMessage(.init(message: ephemeral("Before", anchored: anchored))))
        _ = patch(Api.Update.updateEditEphemeralMessage(.init(message: ephemeral("After", anchored: anchored))))
        check(history(forId: 81301, peer: 42, namespace: anchored ? 8 : 7) == ["Before", "After"], "Ephemeral edits have separate local/anchored histories")
    }
    check(patch(Api.Update.updateDeleteEphemeralMessages(.init(peer: .peerUser(.init(userId: 42)), ids: [81301]))) != nil, "Ephemeral deletions are blocked")
    check(isDeleted(81301, peer: 42, namespace: 7) && isDeleted(81301, peer: 42, namespace: 8), "Ephemeral deletion marks both host namespaces")

    // Full revision metadata records changes even when the caption is unchanged.
    _ = patch(message(81401, text: "Same text"))
    let formatting = message(81401, text: "Same text", edit: 2000)
    messageData(formatting).entities = [.messageEntityItalic(.init(offset: 0, length: 4))]
    _ = patch(formatting)
    check(history(forId: 81401, peer: 42)?.count == 2, "Formatting-only edits retain a revision")
    let formattingDetails = TLParser.editRevisionDetails(forId: 81401, peer: 42, account: testAccount, namespace: 0)!
    check(formattingDetails[1]["formatChanged"] as? Bool == true, "The UI can identify formatting-only revisions")
    func captioned(_ photoId: Int64, edit: Int32?) -> Api.Message {
        message(81402, text: "Caption", media: .messageMediaPhoto(.init(flags: 1, photo: .photoEmpty(.init(id: photoId)), ttlSeconds: nil, video: nil)), edit: edit)
    }
    _ = patch(captioned(1, edit: nil))
    _ = patch(captioned(2, edit: 2000))
    check(history(forId: 81402, peer: 42)?.count == 2, "Media-only edits retain a revision")
    let mediaDetails = TLParser.editRevisionDetails(forId: 81402, peer: 42, account: testAccount, namespace: 0)!
    let previousContent = mediaDetails[0]["content"] as! [String: Data]
    guard case let .messageMediaPhoto(oldPhoto) = parsed(previousContent["media"]! as NSData, as: Api.MessageMedia.self),
          case let .photoEmpty(originalPhoto)? = oldPhoto.photo else { fatalError("Expected saved media") }
    check(originalPhoto.id == 1, "The original attachment metadata survives replacement")
    for (index, phone) in ["123", "456"].enumerated() {
        let contact = Api.MessageMedia.messageMediaContact(.init(phoneNumber: phone, firstName: "Name", lastName: "", vcard: "", userId: 0))
        _ = patch(message(81405, text: "Contact", media: contact, edit: index == 0 ? nil : 2000))
    }
    check(history(forId: 81405, peer: 42)?.count == 2, "Non-photo attachment changes retain revisions too")
    for (index, text) in ["Rich original", "Rich revision"].enumerated() {
        let rich = message(81403, text: "", edit: index == 0 ? nil : 2000)
        messageData(rich).flags2 |= 1 << 13
        messageData(rich).richMessage = .richMessage(.init(flags: 0, blocks: [.pageBlockParagraph(.init(text: .textConcat(.init(texts: [.textBold(.init(text: .textPlain(.init(text: String(text.prefix(4)))))), .textPlain(.init(text: String(text.dropFirst(4))))]))))], photos: [], documents: []))
        _ = patch(rich)
    }
    check(history(forId: 81403, peer: 42) == ["Rich original", "Rich revision"], "Rich messages expose actual text in revision history")

    let sendRequest = Api.functions.messages.sendMessage(flags: 0, peer: .inputPeerUser(.init(userId: 42, accessHash: 1)),
        replyTo: nil, message: "Sent original", randomId: 1, replyMarkup: nil, entities: nil, scheduleDate: nil,
        scheduleRepeatPeriod: nil, sendAs: nil, quickReplyShortcut: nil, effect: nil, allowPaidStars: nil, suggestedPost: nil, richMessage: nil).1.makeData() as NSData
    let compactSent = Api.Updates.updateShortSentMessage(.init(flags: 0, id: 81404, pts: 52, ptsCount: 1, date: 1234, media: nil, entities: nil, ttlPeriod: nil))
    check(TLParser.handleResponse(serialized(compactSent), functionID: -17526942, account: testAccount, requestPayload: sendRequest) == nil, "Recording a compact send preserves response bytes")
    let sentRevision = message(81404, text: "Sent revision", edit: 2000)
    messageData(sentRevision).entities = nil
    messageData(sentRevision).flags &= ~(1 << 7)
    _ = patch(Api.Update.updateEditMessage(.init(message: sentRevision, pts: 53, ptsCount: 1)))
    check(history(forId: 81404, peer: 42) == ["Sent original", "Sent revision"], "Compact send replies retain the outgoing original")

    // Revalidation requests can restore only the requested account/chat/id.
    flags("TGExtraAntiRevoke")
    _ = strip(serialized(message(81500, peer: .peerChannel(.init(channelId: 77)), text: "Saved channel")))
    _ = strip(serialized(message(81500, peer: .peerChannel(.init(channelId: 78)), text: "Other channel")))
    let request = Api.functions.channels.getMessages(channel: .inputChannel(.init(channelId: 77, accessHash: 1)), id: [.inputMessageID(.init(id: 81500))]).1.makeData() as NSData
    let empty = Api.messages.Messages.channelMessages(.init(flags: 0, pts: 55, count: 0, offsetIdOffset: nil, messages: [], topics: [], chats: [], users: []))
    func validate(_ account: String?, bytes: NSData? = nil) -> NSData? {
        TLParser.handleResponse(bytes ?? serialized(empty), functionID: -1383294429, account: account, requestPayload: request)
    }
    check(validate("account-2") == nil && validate(nil) == nil, "Validation never restores another account's snapshot")
    guard case let .channelMessages(restored) = parsed(validate(testAccount)!, as: Api.messages.Messages.self) else { fatalError("Expected restored messages") }
    check(restored.messages.count == 1 && messageData(restored.messages[0]).message == "Saved channel", "Validation restores the exact requested channel")
    check(isDeleted(81500, peer: -1_000_000_000_077) && !isDeleted(81500, peer: -1_000_000_000_078), "Only recovered snapshots are marked deleted")
    let opaqueEmpty = withOpaqueHistoryPeer(empty, suffix: 0, user: true)
    check(validate(testAccount, bytes: opaqueEmpty) != nil, "Validation restores snapshots before opaque peer vectors")
    let placeholder = Api.messages.Messages.channelMessages(.init(flags: 0, pts: 55, count: 0, offsetIdOffset: nil,
        messages: [.messageEmpty(.init(flags: 0, id: 81500, peerId: nil))], topics: [], chats: [], users: []))
    guard case let .channelMessages(replaced) = parsed(validate(testAccount, bytes: serialized(placeholder))!, as: Api.messages.Messages.self) else { fatalError("Expected replacement") }
    check(replaced.messages.count == 1 && messageData(replaced.messages[0]).message == "Saved channel", "messageEmpty is replaced without duplicate ids")
    flags()
    check(validate(testAccount) == nil, "Disabling protection restores the real validation response")

    flags("TGExtraAntiRevoke")
    let malformedContainer = Buffer()
    malformedContainer.appendInt32(0x73f1f8dc)
    malformedContainer.appendInt32(2)
    let validChild = serialized(deletion([81600]))
    malformedContainer.appendInt64(1)
    malformedContainer.appendInt32(1)
    malformedContainer.appendInt32(Int32(validChild.length))
    malformedContainer.appendBytes(validChild.bytes, length: UInt(validChild.length))
    // An incomplete second child must invalidate the container before the
    // first child can write a deletion marker or a snapshot.
    malformedContainer.appendInt64(2)
    malformedContainer.appendInt32(1)
    malformedContainer.appendInt32(4)
    check(strip(malformedContainer.makeData() as NSData) == nil, "Reject incomplete transport containers")
    check(!isDeleted(81600, peer: 42), "Rejected transport containers never record prefix deletions")

    // Small channel ids survive traffic with larger ids in other chats.
    for id in Int32(82000)...Int32(83100) { TLParser.addDeletedId(id, peer: 42, account: testAccount) }
    TLParser.addDeletedId(1, peer: -1_000_000_000_077, account: testAccount)
    check(isDeleted(1, peer: -1_000_000_000_077), "Deletion markers are not evicted by numeric id")
    flags("TGExtraAntiAutoDelete")
    for id in Int32(84000)...Int32(86001) {
        _ = patch(Api.Update.updateNewScheduledMessage(.init(message: message(id, ttl: 60))))
    }
    let oldestTimer = Api.Update.updateDeleteScheduledMessages(.init(flags: 0, peer: .peerUser(.init(userId: 42)), messages: [84000], sentMessages: nil))
    check(patch(oldestTimer) != nil, "Timer protection survives more than 2000 classified messages")
    TLParser.clearMessageData()
    check(defaults.object(forKey: "TGExtraObservedMessages") == nil && defaults.object(forKey: "TGExtraMessageMarkersByAccount") == nil, "Clearing removes all new message stores")
    print("PASS account/namespace isolation, all TTL containers, special updates, full revisions, validation recovery and marker retention")
}
