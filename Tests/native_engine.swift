import Foundation
import TestSupport

func testNativeEngine() {
    check(TLParser.nativeTLAvailable(), "The verified native fixture engine is installed")
    func native(_ value: Any, function: Int32 = 0, request: Data? = nil, patch: Bool = true,
                account: String? = testAccount) -> NSData? {
        TGExtraNativeFixtureParse(serialized(value) as Data, account, function, request, patch) as NSData?
    }
    let uuid = Data(0..<16)
    let metadata: [String: Any] = ["ABI": 1, "UUID": uuid, "constructor": 123, "result": 456]
    check(TGExtraNativeTestConfig(metadata, uuid, 123, 456), "Accept the engine's binary plist UUID")
    check(!TGExtraNativeTestConfig(metadata, Data(repeating: 0, count: 16), 123, 456) &&
          !TGExtraNativeTestConfig(metadata, uuid, 124, 456), "Reject stale native installation metadata")
    flags()
    let original = message(99001)
    messageData(original).flags |= 1 << 26
    let before = TGExtraNativeFixtureParseCount()
    let plain = native(original, patch: false)!
    let baselineCalls = TGExtraNativeFixtureParseCount() - before
    let after = TGExtraNativeFixtureParseCount()
    check(native(original) == plain, "Native content access preserves forwarding flags while its switch is off")
    check(TGExtraNativeFixtureParseCount() - after == baselineCalls, "The packet is decoded exactly once")

    flags("disableForwardRestriction")
    let forwarded = parsed(native(original)!, as: Api.Message.self)
    check(messageData(forwarded).flags & (1 << 26) == 0, "Native forwarding rule edits the host flags")
    messageData(original).flags |= 1 << 22
    messageData(original).restrictionReason = [.restrictionReason(.init(platform: "ios", reason: "appleterms", text: "Blocked"))]
    flags()
    let unrestricted = parsed(native(original)!, as: Api.Message.self)
    check(messageData(unrestricted).restrictionReason == nil && messageData(unrestricted).flags & (1 << 26) != 0,
          "Unconditional native content access retains independent forwarding protection")

    flags("TGExtraAntiAutoDelete")
    let timed = message(99002, ttl: 60)
    let historyPacket = Api.messages.Messages.messages(.init(messages: [timed], topics: [], chats: [], users: []))
    guard case let .messages(messages) = parsed(native(historyPacket)!, as: Api.messages.Messages.self) else { fatalError("Expected native history") }
    check(messageData(messages.messages[0]).ttlPeriod == nil, "Native TTL rules clear scalar presence and wire flags")
    let deletion = Api.Update.updateDeleteMessages(.init(messages: [99002, 99003], pts: 10, ptsCount: 2))
    guard case let .updateDeleteMessages(kept) = parsed(native(deletion)!, as: Api.Update.self) else { fatalError("Expected native deletion") }
    check(kept.messages == [0, 99003] && kept.pts == 10, "Native deletion classification preserves synchronization counters")

    flags("TGExtraAntiEdit")
    _ = native(message(99004, text: "Before"))
    _ = native(message(99004, text: "After", edit: 2000))
    check(history(forId: 99004, peer: 42) == ["Before", "After"], "Native observation retains edit history")
    let invalid = (serialized(message(99005)) as Data).dropLast(4)
    check(TGExtraNativeFixtureParse(invalid, testAccount, 0, nil, true) == nil, "Reject incomplete native packets")
    check(history(forId: 99005, peer: 42) == nil, "An incomplete decode cannot publish history")

    flags("TGExtraAntiSelfDestruct")
    let media = Api.MessageMedia.messageMediaPhoto(.init(flags: 4, photo: nil, ttlSeconds: 10, video: nil))
    let disappearing = parsed(native(message(99006, media: media))!, as: Api.Message.self)
    guard case let .messageMediaPhoto(photo)? = messageData(disappearing).media else { fatalError("Expected native photo") }
    check(photo.ttlSeconds == nil && messageData(disappearing).message.hasPrefix("dissapearing message "),
          "Native media protection retains marker text and newly created entities")
    flags("TGExtraAntiRevoke")
    let request = Api.functions.messages.getMessages(id: [.inputMessageID(.init(id: 99002))]).1.makeData()
    let empty = Api.messages.Messages.messages(.init(messages: [], topics: [], chats: [], users: []))
    guard case let .messages(restored) = parsed(native(empty, function: 1673946374, request: request)!, as: Api.messages.Messages.self) else { fatalError("Expected restored native snapshot") }
    check(restored.messages.count == 1 && messageData(restored.messages[0]).id == 99002,
          "Native getMessages recovery materializes saved messages without reparsing the packet")

    let fullBytes = Buffer()
    fullBytes.appendInt32(Int32(bitPattern: 0xb90c2afd)); fullBytes.appendInt32(0)
    fullBytes.appendInt32((1 << 23) | (1 << 24)); fullBytes.appendInt64(42)
    fullBytes.appendInt32(Int32(bitPattern: 0xf47741f7)); fullBytes.appendInt32(0)
    fullBytes.appendInt32(Int32(bitPattern: 0x99622c0c)); fullBytes.appendInt32(0); fullBytes.appendInt32(7)
    let full = parsed(fullBytes.makeData() as NSData, as: Api.UserFull.self)
    flags("TGExtraIgnorePrivateChatCopyProtection", "disableForwardRestriction")
    guard case let .userFull(privateUser) = parsed(native(full)!, as: Api.UserFull.self) else { fatalError("Expected native full user") }
    check(privateUser.flags2 & ((1 << 23) | (1 << 24)) == 0, "Native private-copy rule clears both flags")
    let channel = Buffer()
    channel.appendInt32(Int32(bitPattern: 0x7ad15240)); channel.appendInt32(1 << 27)
    channel.appendInt32(0); channel.appendInt64(77); serializeString("Channel", buffer: channel, boxed: false)
    channel.appendInt32(0x37c1011c); channel.appendInt32(0)
    let chats = [parsed(channel.makeData() as NSData, as: Api.Chat.self)]
    let envelope = Api.users.UserFull.userFull(.init(fullUser: full, chats: chats, users: []))
    guard case let .userFull(privateEnvelope) = parsed(native(envelope)!, as: Api.users.UserFull.self),
          case let .channel(unrelated) = privateEnvelope.chats[0] else { fatalError("Expected native profile response") }
    check(unrelated.flags & (1 << 27) != 0, "Private-copy handling preserves unrelated chat forwarding flags")

    flags()
    let users = Buffer()
    users.appendInt32(481674261); users.appendInt32(1)
    users.appendInt32(Int32(bitPattern: 0xb1b8cc83)); users.appendInt32((1 << 10) | (1 << 1)); users.appendInt32(0)
    users.appendInt64(4242); serializeString("Native user", buffer: users, boxed: false)
    check(TGExtraNativeFixtureParse(users.makeData(), "account-4242", 227648840, nil, true) != nil,
          "Native function-result bridge handles bare user vectors")
    check((defaults.dictionary(forKey: "TGExtraOwnUserIdsByAccount")?["account-4242"] as? NSNumber)?.int64Value == 4242,
          "Bare native user vectors learn the requesting account's own ID")

    flags("TGExtraAntiRevoke")
    let boolCalls = TGExtraNativeFixtureParseCount()
    _ = native(Api.Bool.boolTrue)
    check(TGExtraNativeFixtureParseCount() - boolCalls == 1,
          "Fieldless views keep their original native backing object")
    flags()
    let config = Api.help.AppConfig.appConfig(.init(hash: 123456,
        config: .jsonObject(.init(value: []))))
    guard case let .appConfig(configData) = parsed(native(config, account: nil)!, as: Api.help.AppConfig.self),
          case let .jsonObject(configObject) = configData.config,
          case let .jsonObjectValue(ignore)? = configObject.value.first,
          case let .jsonArray(reasons) = ignore.value else { fatalError("Expected native config policy") }
    check(configData.hash == 123456 && ignore.key == "ignore_restriction_reasons" && reasons.value.count == 2,
          "Native configuration rules retain the server hash and materialize new JSON values")

    flags("TGExtraAntiEdit")
    DispatchQueue.concurrentPerform(iterations: 2) { index in
        autoreleasepool {
            let text = "Account \(index)"
            _ = native(message(99007, text: text), account: "native-account-\(index)")
            _ = native(message(99007, text: "Edited \(index)", edit: 2000), account: "native-account-\(index)")
        }
    }
    for index in 0..<2 {
        check(history(forId: 99007, peer: 42, account: "native-account-\(index)") == ["Account \(index)", "Edited \(index)"],
              "Concurrent native transactions isolate account history")
    }
    flags("disableForwardRestriction")
    let lifetimePacket = serialized(original) as Data
    autoreleasepool { _ = TGExtraNativeFixtureDecode(lifetimePacket, nil, 0, nil, true) }
    let liveBefore = TGExtraNativeFixtureLiveCount()
    for _ in 0..<100 {
        autoreleasepool { _ = TGExtraNativeFixtureDecode(lifetimePacket, nil, 0, nil, true) }
    }
    check(TGExtraNativeFixtureLiveCount() == liveBefore, "Native bridge balances decoded object ownership")
    flags()
    print("PASS native host engine: one decode, content, forwarding, TTL, deletions, edit history, rejected packets and labels")
}

func benchmarkNativeEngine() {
    _ = TLParser.nativeTLAvailable()
    TGExtraNativeFixtureEnable()
    let messages = (1...100).map { message(Int32($0)) }
    let packet = Api.messages.Messages.messages(.init(messages: messages, topics: [], chats: [], users: []))
    let data = serialized(packet) as Data
    let timed = serialized(Api.messages.Messages.messages(.init(messages: (1...100).map { message(Int32($0), ttl: 60) }, topics: [], chats: [], users: []))) as Data
    var checksum = 0
    let selected = ProcessInfo.processInfo.environment["TGEXTRA_NATIVE_STAGE"]
    let iterations = Int(ProcessInfo.processInfo.environment["TGEXTRA_NATIVE_ITERATIONS"] ?? "500") ?? 500
    func measure(_ name: String, bytes: Data, native: Bool, wire: Bool = false) {
        if let selected = selected, selected != name { return }
        for _ in 0..<20 { _ = TGExtraNativeFixtureDecode(bytes, nil, 0, nil, native) }
        var samples = [Double]()
        for _ in 0..<5 {
            let start = DispatchTime.now().uptimeNanoseconds
            for _ in 0..<iterations {
                autoreleasepool {
                    let input = wire ? (TLParser.stripAntiSelfDestruct(bytes as NSData, account: nil) as Data? ?? bytes) : bytes
                    precondition(TGExtraNativeFixtureDecode(input, nil, 0, nil, native) != nil)
                    checksum += 1
                }
            }
            samples.append(Double(DispatchTime.now().uptimeNanoseconds-start)/Double(iterations)/1_000_000)
        }
        print("NATIVE_BENCH \(name) median_ms=\(samples.sorted()[2]) samples=\(samples)")
    }
    flags()
    measure("host", bytes: data, native: false)
    measure("wire/off", bytes: data, native: false, wire: true)
    measure("native/off", bytes: data, native: true)
    flags("disableForwardRestriction")
    measure("wire/forward", bytes: data, native: false, wire: true)
    measure("native/forward", bytes: data, native: true)
    flags("TGExtraAntiAutoDelete")
    measure("wire/ttl", bytes: timed, native: false, wire: true)
    measure("native/ttl", bytes: timed, native: true)
    print("NATIVE_CHECKSUM \(checksum)")
}
