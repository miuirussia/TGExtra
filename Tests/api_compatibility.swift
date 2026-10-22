import Foundation

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
        Api.RestrictionReason.restrictionReason(.init(platform: "ios", reason: "sensitive", text: "Unavailable on iOS")).serialize(buffer, true)
    }
    func channel(restricted: Bool, legacy: Bool = false, forwarding: Bool = true) -> Data {
        let buffer = Buffer()
        buffer.appendInt32(legacy ? -727763770 : 0x7ad15240)
        buffer.appendInt32((forwarding ? 1 << 27 : 0) | (restricted ? 1 << 9 : 0))
        buffer.appendInt32(legacy ? 0 : 1 << 22)
        buffer.appendInt64(77)
        serializeString("Restricted channel", buffer: buffer, boxed: false)
        buffer.appendInt32(0x37c1011c)
        buffer.appendInt32(1234)
        if restricted { reason(buffer) }
        if !legacy { buffer.appendInt32(456) } // pinned_msg_id must survive vector removal.
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
    let oldBlocked = channel(restricted: true, legacy: true)
    let oldAllowed = channel(restricted: false, legacy: true)
    check(strip(oldBlocked as NSData) == oldAllowed as NSData,
          "Telegram 13.0 channel restrictions are removed without changing its constructor")
    flags("disableForwardRestriction")
    check(strip(chats(oldBlocked)) == chats(channel(restricted: false, legacy: true, forwarding: false)),
          "Combined content/forward rewrites preserve the 13.0 channel constructor")
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

func testLegacyApiConstructors() {
    // Minimal 13.0 wire objects: none may be re-encoded with a 13.1 ID.
    func fixture(_ id: Int32, _ fields: (Buffer) -> Void) -> NSData {
        let buffer = Buffer()
        buffer.appendInt32(id)
        fields(buffer)
        return buffer.makeData() as NSData
    }
    func text(_ value: String, _ buffer: Buffer) { serializeString(value, buffer: buffer, boxed: false) }
    func notify(_ buffer: Buffer) { buffer.appendInt32(Int32(bitPattern: 0x99622c0c)); buffer.appendInt32(0) }
    let fixtures = [
        fixture(-727763770) { b in // channel
            b.appendInt32(0); b.appendInt32(0); b.appendInt64(77)
            text("Legacy channel", b); b.appendInt32(0x37c1011c); b.appendInt32(1234)
        },
        fixture(-1605464774) { b in // channelFull
            b.appendInt32(0); b.appendInt32(0); b.appendInt64(77); text("About", b)
            b.appendInt32(1); b.appendInt32(2); b.appendInt32(3)
            Api.Photo.photoEmpty(.init(id: 9)).serialize(b, true); notify(b)
            b.appendInt32(481674261); b.appendInt32(0); b.appendInt32(50)
        },
        fixture(1003796418) { b in b.appendInt32(0); b.appendInt32(42) }, // inputReplyToMessage
        fixture(462937446) { b in b.appendInt32(1 << 4); b.appendInt32(42) }, // messageReplyHeader
        fixture(1020666860) { b in // urlAuthResultRequest
            b.appendInt32(0); Api.User.userEmpty(.init(id: 42)).serialize(b, true); text("example.org", b)
        },
        fixture(114026053) { b in // userFull
            b.appendInt32(0); b.appendInt32(0); b.appendInt64(42)
            b.appendInt32(Int32(bitPattern: 0xf47741f7)); b.appendInt32(0); notify(b); b.appendInt32(7)
        },
        fixture(876739868) { b in // wallet.nftItem
            b.appendInt32(0); text("address", b); text("owner", b); text("1", b)
        },
    ]
    for bytes in fixtures {
        let reader = BufferReader(Buffer(nsData: bytes))
        let id = reader.readInt32()!
        check(Api.isKnownConstructor(id), "The previous API constructor remains registered: \(id)")
        guard let value = Api.parse(reader, signature: id) else { fatalError("Could not decode Telegram 13.0 constructor \(id)") }
        check(reader.offset == UInt(bytes.length) && serialized(value) == bytes,
              "Telegram 13.0 constructor \(id) round-trips without upgrading its wire format")
    }
    print("PASS all seven replaced Telegram 13.0 constructors and original wire IDs")
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
