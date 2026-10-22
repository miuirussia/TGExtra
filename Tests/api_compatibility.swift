import Foundation

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
    let decodedChannel = parsed(channel.makeData() as NSData, as: Api.Chat.self)
    guard case let .channel(channelData) = decodedChannel else { fatalError("Expected channel") }
    check(channelData.pinnedMsgId == 81234 && channelData.flags & (1 << 27) == 0,
          "Decode new channel fields and retain the existing noforwards bypass")

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
