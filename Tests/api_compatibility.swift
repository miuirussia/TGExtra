import Foundation
import TestSupport

func testContentRestrictions() {
    flags()
    let savedAccounts = defaults.object(forKey: "TGExtraOwnUserIdsByAccount")
    defaults.set([testAccount: 999], forKey: "TGExtraOwnUserIdsByAccount")
    defer {
        defaults.set(savedAccounts, forKey: "TGExtraOwnUserIdsByAccount")
        flags()
    }
    func reason(_ buffer: Buffer) {
        buffer.appendInt32(481674261)
        buffer.appendInt32(1)
        Api.RestrictionReason.restrictionReason(.init(platform: "ios", reason: "appleterms-ios", text: "Unavailable on iOS")).serialize(buffer, true)
    }
    func channel(restricted: Bool, forwarding: Bool = true) -> Data {
        let buffer = Buffer()
        buffer.appendInt32(0x7ad15240)
        buffer.appendInt32((forwarding ? 1 << 27 : 0) | (restricted ? 1 << 9 : 0))
        buffer.appendInt32(1 << 22)
        buffer.appendInt64(77)
        serializeString("Restricted channel", buffer: buffer, boxed: false)
        buffer.appendInt32(0x37c1011c)
        buffer.appendInt32(1234)
        if restricted { reason(buffer) }
        buffer.appendInt32(456) // pinned_msg_id must survive vector removal.
        return buffer.makeData()
    }
    let blocked = channel(restricted: true), allowed = channel(restricted: false)
    check(strip(blocked as NSData) == allowed as NSData,
          "iOS channel restrictions are removed with all toggles off and a known account")
    check(strip(blocked as NSData, account: nil) == allowed as NSData,
          "Content access does not require a resolved account")
    check(strip(allowed as NSData) == nil, "The content bypass does not change forwarding flags on its own")

    func chats(_ channel: Data) -> NSData {
        let buffer = Buffer()
        let empty = serialized(Api.messages.Chats.chats(.init(chats: [])))
        buffer.appendBytes(empty.bytes, length: 4)
        buffer.appendInt32(481674261); buffer.appendInt32(1)
        channel.withUnsafeBytes { buffer.appendBytes($0.baseAddress!, length: UInt($0.count)) }
        return buffer.makeData() as NSData
    }
    check(response(chats(blocked), functionID: 176122811) == chats(allowed),
          "Channel lookup responses deliver the patched restrictions to the host")
    flags("disableForwardRestriction")
    check(strip(chats(blocked)) == chats(channel(restricted: false, forwarding: false)),
          "Content and forwarding rewrites compose")
    flags()

    func user(_ id: Int64, restricted: Bool) -> Data {
        let buffer = Buffer()
        buffer.appendInt32(Int32(bitPattern: 0xb1b8cc83))
        buffer.appendInt32(restricted ? 1 << 18 : 0)
        buffer.appendInt32(0)
        buffer.appendInt64(id)
        if restricted { reason(buffer) }
        return buffer.makeData()
    }
    func vector(_ users: [Data]) -> NSData {
        let buffer = Buffer()
        buffer.appendInt32(481674261); buffer.appendInt32(Int32(users.count))
        for user in users { user.withUnsafeBytes { buffer.appendBytes($0.baseAddress!, length: UInt($0.count)) } }
        return buffer.makeData() as NSData
    }
    let blockedUsers = vector([user(42, restricted: true), user(43, restricted: true)])
    let allowedUsers = vector([user(42, restricted: false), user(43, restricted: false)])
    check(response(blockedUsers, functionID: 227648840) == allowedUsers,
          "Bare users.getUsers vectors strip every user's iOS restriction")

    func append(_ data: Data, to buffer: Buffer) {
        data.withUnsafeBytes { buffer.appendBytes($0.baseAddress!, length: UInt($0.count)) }
    }
    func opaquePeer(_ buffer: Buffer) {
        buffer.appendInt32(481674261); buffer.appendInt32(1)
        buffer.appendInt32(1234567); buffer.appendInt32(0)
    }
    func history(_ channel: Data, messages: [Api.Message]) -> NSData {
        let buffer = Buffer()
        buffer.appendInt32(494135274) // messages.messages
        buffer.appendInt32(481674261); buffer.appendInt32(Int32(messages.count))
        for message in messages { message.serialize(buffer, true) }
        buffer.appendInt32(481674261); buffer.appendInt32(0) // topics
        buffer.appendInt32(481674261); buffer.appendInt32(1); append(channel, to: buffer)
        opaquePeer(buffer) // unknown User after the known restricted Chat
        return buffer.makeData() as NSData
    }
    for timed in [false, true] {
        if timed { flags("TGExtraAntiAutoDelete") } else { flags() }
        let source = message(89100, ttl: timed ? 60 : nil)
        let bytes = history(channel(restricted: true), messages: [source])
        let patched = strip(bytes)!
        let reader = BufferReader(Buffer(nsData: patched))
        reader.skip(12)
        let result = Api.parse(reader, signature: reader.readInt32()!) as! Api.Message
        check(messageData(result).ttlPeriod == nil, "Opaque history still removes message timers")
        check(patched == history(channel(restricted: false), messages: [result]),
              "Content edits in known chats survive message rewrites and preserve unknown users, wire IDs and forwarding flags")
    }
    func updates(_ values: [Api.Update], restricted: Bool, combined: Bool) -> NSData {
        let buffer = Buffer()
        buffer.appendInt32(combined ? 1918567619 : 1957577280)
        buffer.appendInt32(481674261); buffer.appendInt32(Int32(values.count))
        for value in values { value.serialize(buffer, true) }
        append((restricted ? blockedUsers : allowedUsers) as Data, to: buffer)
        opaquePeer(buffer) // unknown Chat after the known restricted Users
        buffer.appendInt32(1234)
        if combined { buffer.appendInt32(7) }
        buffer.appendInt32(8)
        return buffer.makeData() as NSData
    }
    for combined in [false, true] {
        flags()
        check(strip(updates([], restricted: true, combined: combined)) == updates([], restricted: false, combined: combined),
              "Opaque updates remove user restrictions even without a rewritten update")
        flags("TGExtraAntiAutoDelete")
        let source = message(89101, ttl: 60)
        messageData(source).flags |= 1 << 22
        messageData(source).restrictionReason = [.restrictionReason(.init(platform: "ios", reason: "appleterms-ios", text: "Blocked"))]
        let update = Api.Update.updateNewMessage(.init(message: source, pts: 5, ptsCount: 1))
        let expected = parsed(patch(update)!, as: Api.Update.self)
        check(strip(updates([update], restricted: true, combined: combined)) == updates([expected], restricted: false, combined: combined),
              "Overlapping message content edits apply once; user edits and the opaque trailer survive shrinking updates")
        flags("TGExtraAntiRevoke")
        check(strip(updates([deletion([89102])], restricted: true, combined: combined)) == updates([deletion([0])], restricted: false, combined: combined),
              "User content edits compose with deletion rewrites in opaque updates")
    }
    flags()

    let packed = Buffer()
    packed.appendInt32(0x3072cfa1)
    serializeBytes(Buffer(data: gzip(blocked)), buffer: packed, boxed: false)
    check(strip(packed.makeData() as NSData) == allowed as NSData, "Content bypass works through gzip with optional features off")
    for length in 0..<blocked.count {
        check(strip(blocked.prefix(length) as NSData) == nil, "Truncated restricted channels remain untouched")
    }
    check(strip((blocked + Data([0, 0, 0, 0])) as NSData) == nil, "Unknown channel trailers remain untouched")
    print("PASS always-on iOS content access, known/unknown accounts, channel lookups, bare user vectors and malformed data")
}

func testSnapshotApiCompatibility() {
    flags("TGExtraAntiRevoke")
    defer { flags(); TLParser.clearMessageData() }
    let reply = Buffer()
    reply.appendInt32(-575296651) // messageReplyHeader in Telegram 13.1+
    reply.appendInt32(1 << 4); reply.appendInt32(7)
    let header = parsed(reply.makeData() as NSData, as: Api.MessageReplyHeader.self)
    for service in [false, true] {
        let id: Int32 = service ? 89201 : 89200
        let cached: Api.Message
        if service {
            cached = .messageService(.init(flags: 1 << 3, id: id, fromId: nil,
                peerId: .peerUser(.init(userId: 42)), savedPeerId: nil, replyTo: header,
                date: 1234, action: .messageActionEmpty, reactions: nil, ttlPeriod: nil))
        } else {
            cached = message(id)
            messageData(cached).flags |= 1 << 3
            messageData(cached).replyTo = header
        }
        check(strip(serialized(cached)) == nil, "Observing a message preserves its wire format")
        let request = Api.functions.messages.getMessages(id: [.inputMessageID(.init(id: id))]).1.makeData() as NSData
        let empty = serialized(Api.messages.Messages.messages(.init(messages: [], topics: [], chats: [], users: [])))
        let bytes = TLParser.handleResponse(empty, functionID: 1673946374, account: testAccount, requestPayload: request)!
        guard case let .messages(result) = parsed(bytes, as: Api.messages.Messages.self) else { fatalError("Expected restored snapshot") }
        let restoredHeader: Api.MessageReplyHeader
        switch result.messages[0] {
        case let .message(data): restoredHeader = data.replyTo!
        case let .messageService(data): restoredHeader = data.replyTo!
        default: fatalError("Expected restored message")
        }
        check(serialized(restoredHeader) == reply.makeData() as NSData, "Snapshot recovery preserves reply fields")
    }
    print("PASS Telegram 13.1+ snapshot reply recovery")
}

func testUnsupportedApiConstructors() {
    let oldIds: [Int32] = [-727763770, -1605464774, 1003796418, 462937446, 1020666860, 114026053, 876739868]
    for id in oldIds {
        check(!Api.isKnownConstructor(id), "Pre-13.1 constructor aliases are not registered")
        let buffer = Buffer()
        buffer.appendInt32(id)
        buffer.appendInt32(0)
        check(strip(buffer.makeData() as NSData) == nil, "Unsupported objects remain untouched")
    }
    print("PASS unsupported pre-13.1 constructors")
}

func testUpdatedApi() {
    // Wire fixtures spell out the new IDs/field order independently of the
    // generated serializers, so a matching old encoder/decoder cannot pass.
    let channel = Buffer()
    channel.appendInt32(Int32(bitPattern: 0x7ad15240))
    channel.appendInt32(1 << 27)
    channel.appendInt32(1 << 22)
    channel.appendInt64(77)
    serializeString("API 13.1 channel", buffer: channel, boxed: false)
    channel.appendInt32(0x37c1011c) // chatPhotoEmpty
    channel.appendInt32(1234)
    channel.appendInt32(81234) // flags2.22: pinned_msg_id
    let channelReader = BufferReader(channel)
    let decodedChannel = Api.parse(channelReader, signature: channelReader.readInt32()!) as! Api.Chat
    guard case let .channel(channelData) = decodedChannel else { fatalError("Expected channel") }
    check(channelData.pinnedMsgId == 81234 && channelData.flags & (1 << 27) != 0 &&
          serialized(decodedChannel) == channel.makeData() as NSData,
          "Decode new channel fields without changing the original protection flag")
    MessagePatches.prepareDecodedObjects(in: channelReader)
    check(channelData.flags & (1 << 27) == 0 && channelReader.wireEdits.isEmpty,
          "Explicit preparation retains the forwarding bypass in the decoded copy")

    let update = Api.Updates.updates(.init(
        updates: [.updateNewChannelMessage(.init(message: message(89001, peer: .peerChannel(.init(channelId: 77)), ttl: 60), pts: 1, ptsCount: 1))],
        users: [], chats: [decodedChannel], date: 1234, seq: 1))
    flags("TGExtraAntiAutoDelete")
    guard case let .updates(patched) = parsed(patch(update)!, as: Api.Updates.self),
          case let .channel(patchedChannel) = patched.chats[0],
          case let .updateNewChannelMessage(patchedUpdate) = patched.updates[0] else { fatalError("Expected patched update") }
    check(patchedChannel.pinnedMsgId == 81234 && messageData(patchedUpdate.message).ttlPeriod == nil,
          "TTL rewriting preserves the new channel constructor and pinned message")

    let user = Buffer()
    user.appendInt32(Int32(bitPattern: 0xb90c2afd))
    user.appendInt32(0)
    let userFlags: Int32 = (1 << 19) | (1 << 23) | (1 << 24) | (1 << 26) | (1 << 27)
    user.appendInt32(userFlags)
    user.appendInt64(42)
    user.appendInt32(Int32(bitPattern: 0xf47741f7)) // peerSettings
    user.appendInt32(0)
    user.appendInt32(Int32(bitPattern: 0x99622c0c)) // peerNotifySettings
    user.appendInt32(0)
    user.appendInt32(7) // common_chats_count
    user.appendInt32(Int32(bitPattern: 0x8ed043b1)) // wallet.card
    user.appendInt32(0)
    serializeString("UQ-test-address", buffer: user, boxed: false)
    user.appendInt64(123456789)
    user.appendInt32(Int32(bitPattern: 0x95ace84f)) // shareThemeDefault
    let userBytes = user.makeData() as NSData
    let decodedUser = parsed(userBytes, as: Api.UserFull.self)
    check(serialized(decodedUser) == userBytes, "New full-user wallet and share-theme fields round-trip byte for byte")
    flags("TGExtraIgnorePrivateChatCopyProtection")
    let patchedUserBytes = strip(userBytes)!
    guard case let .userFull(patchedUser) = parsed(patchedUserBytes, as: Api.UserFull.self),
          case let .card(card)? = patchedUser.walletCard,
          case .shareThemeDefault? = patchedUser.shareTheme else { fatalError("Expected new full-user fields") }
    check(patchedUser.flags2 == userFlags & ~((1 << 23) | (1 << 24)) &&
          card.address == "UQ-test-address" && card.balance == 123456789,
          "Private-copy bypass preserves the wallet, theme and unrelated flags")
    check((patchedUserBytes as Data).prefix(8) == (userBytes as Data).prefix(8) &&
          (patchedUserBytes as Data).dropFirst(12) == (userBytes as Data).dropFirst(12),
          "Only the private-copy flags change in the new full-user wire fixture")
    for length in 0..<userBytes.length {
        check(strip((userBytes as Data).prefix(length) as NSData) == nil,
              "Truncated new full-user data passes through safely")
    }

    let richQuote: [Api.RichText] = [.textBold(.init(text: .textPlain(.init(text: "Quoted text"))))]
    func quoteVector(_ buffer: Buffer) {
        buffer.appendInt32(481674261)
        buffer.appendInt32(1)
        richQuote[0].serialize(buffer, true)
    }
    let replyHeader = Buffer()
    replyHeader.appendInt32(Int32(bitPattern: 0xddb5ab75))
    replyHeader.appendInt32((1 << 4) | (1 << 14))
    replyHeader.appendInt32(81234)
    quoteVector(replyHeader)
    let reply = parsed(replyHeader.makeData() as NSData, as: Api.MessageReplyHeader.self)
    check(serialized(reply) == replyHeader.makeData() as NSData, "New rich reply header round-trips")
    let quoted = message(89002, ttl: 60)
    messageData(quoted).flags |= 1 << 3
    messageData(quoted).replyTo = reply
    flags("TGExtraAntiAutoDelete")
    let patchedMessage = messageData(parsed(patch(quoted)!, as: Api.Message.self))
    check(patchedMessage.ttlPeriod == nil && serialized(patchedMessage.replyTo!) == replyHeader.makeData() as NSData,
          "Message rewriting retains rich quotes")

    let inputReply = Buffer()
    inputReply.appendInt32(0x75c1ad70)
    inputReply.appendInt32(1 << 8)
    inputReply.appendInt32(81234)
    quoteVector(inputReply)
    let parsedInput = parsed(inputReply.makeData() as NSData, as: Api.InputReplyTo.self)
    check(serialized(parsedInput) == inputReply.makeData() as NSData, "New input reply accepts rich quotes")
    let forward = Api.functions.messages.forwardMessages(flags: 1 << 22,
        fromPeer: .inputPeerUser(.init(userId: 42, accessHash: 1)), id: [89003], randomId: [9001],
        toPeer: .inputPeerUser(.init(userId: 99, accessHash: 2)), topMsgId: nil, replyTo: parsedInput,
        scheduleDate: nil, scheduleRepeatPeriod: nil, sendAs: nil, quickReplyShortcut: nil,
        effect: nil, videoTimestamp: nil, allowPaidStars: nil, suggestedPost: nil).1.makeData()
    let plan = ForwardCopyPlan(payload: forward)!
    let history = serialized(Api.messages.Messages.messages(.init(messages: [message(89003)], topics: [], chats: [], users: []))) as Data
    check(plan.prepare(response: history) && plan.buildRequests(), "Protected copies support the new input-reply constructor")
    let request = BufferReader(Buffer(data: (plan.requests[0]["payload"] as! Data)))
    _ = request.readInt32(); _ = request.readInt32()
    _ = Api.parse(request, signature: request.readInt32()!) as! Api.InputPeer
    let sentReply = Api.parse(request, signature: request.readInt32()!) as! Api.InputReplyTo
    check(serialized(sentReply) == inputReply.makeData() as NSData, "Protected copies preserve the rich quote in reply_to")
    flags()
    print("PASS Telegram 13.1 wire fixtures, channel pins, wallet/share themes, rich replies, TTL and protected copies")
}
