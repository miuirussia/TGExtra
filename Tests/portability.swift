import Foundation
import TestSupport
import tgapiC

func testProtocolPortability() {
    let original = HostSchema.shared!
    let messageDescriptor = original.constructor(type: "Message", name: "message")!
    let collision = TLField(name: "futureOptional", kind: 0, elementKind: 0, optional: true,
        boxedVector: false, bare: false, flagsIndex: 0, flagBit: 26, typeIndex: 0, constructorIndex: 0)
    let collisionDescriptor = TLConstructor(name: messageDescriptor.name, signature: messageDescriptor.signature,
        typeIndex: messageDescriptor.typeIndex, caseIndex: messageDescriptor.caseIndex, fields: messageDescriptor.fields + [collision])
    let colliding = TLRecord(descriptor: collisionDescriptor, type: "Message")
    colliding["flags"] = Int32(1 << 26)
    check(!TLDataPatch(colliding).clearFlag(.noForwards) && colliding["flags"] as? Int32 == 1 << 26,
          "Reviewed standalone flags cannot clear a host's new optional-field bit")
    let blob = try! Data(contentsOf: URL(fileURLWithPath: ProcessInfo.processInfo.environment["TGEXTRA_TL_SCHEMA"]!))
    var image = decompressGzip((blob as NSData).bytes, blob.count)!
    func u32(_ at: Int) -> Int {
        image.withUnsafeBytes { Int(UInt32(littleEndian: $0.loadUnaligned(fromByteOffset: at, as: UInt32.self))) }
    }
    func u16(_ at: Int) -> Int {
        image.withUnsafeBytes { Int(UInt16(littleEndian: $0.loadUnaligned(fromByteOffset: at, as: UInt16.self))) }
    }
    func put32(_ at: Int, _ value: UInt32) {
        var value = value.littleEndian
        withUnsafeBytes(of: &value) { image.replaceSubrange(at..<at + 4, with: $0) }
    }
    func string(_ offset: Int) -> String {
        let start = u32(40) + offset
        let end = image[start...].firstIndex(of: 0)!
        return String(data: image[start..<end], encoding: .utf8)!
    }
    let functions = u32(64), fields = u32(60), constructors = u32(56)
    var hashName = 0
    for i in 0..<u32(28) {
        let p = functions + i * 28
        if string(u32(p)) == "help.getAppConfig" { hashName = u32(fields + u32(p + 8) * 20) }
    }
    for i in 0..<u32(28) {
        let p = functions + i * 28
        let name = string(u32(p))
        put32(p + 4, UInt32(u32(p + 4)) &+ 0x10000000)
        let first = fields + u32(p + 8) * 20
        if name == "messages.setTyping" {
            let peer = image.subdata(in: first + 20..<first + 40)
            let action = image.subdata(in: first + 60..<first + 80)
            image.replaceSubrange(first + 20..<first + 40, with: action)
            image.replaceSubrange(first + 60..<first + 80, with: peer)
        }
        if name == "channels.readMessageContents" {
            let channel = image.subdata(in: first..<first + 20)
            let ids = image.subdata(in: first + 20..<first + 40)
            image.replaceSubrange(first..<first + 20, with: ids)
            image.replaceSubrange(first + 20..<first + 40, with: channel)
        }
        if name == "messages.sendMedia" {
            for j in 0..<u16(p + 12) {
                let f = first + j * 20
                if string(u32(f)) == "scheduleRepeatPeriod" {
                    // A new required scalar that this tweak's generated view
                    // does not name. It must survive media rewrites.
                    put32(f, UInt32(hashName))
                    image[f + 6] = 0
                    image[f + 9] = 255
                }
            }
        }
        if name == "messages.forwardMessages" {
            for j in 0..<u16(p + 12) {
                let f = first + j * 20
                if string(u32(f)) == "scheduleDate" { image[f + 10] = 7 }
            }
        }
    }
    let changedConstructors = Set(["inputMediaUploadedDocument", "inputPeerUser", "sendMessageTypingAction", "boolTrue", "boolFalse", "messages"])
    var rows = [Data]()
    for i in 0..<u32(24) {
        let p = constructors + i * 28
        if changedConstructors.contains(string(u32(p))) { put32(p + 4, UInt32(u32(p + 4)) &+ 0x20000000) }
        rows.append(image.subdata(in: p..<p + 28))
    }
    rows.sort { a, b in
        a.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 4, as: UInt32.self) } <
        b.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 4, as: UInt32.self) }
    }
    for (i, row) in rows.enumerated() { image.replaceSubrange(constructors + i * 28..<constructors + (i + 1) * 28, with: row) }
    let newer = HostSchema(image: image)!
    let savedDefaults = defaults.dictionaryRepresentation()
    HostSchema.testSchema = newer
    defer {
        HostSchema.testSchema = nil
        for key in defaults.dictionaryRepresentation().keys where savedDefaults[key] == nil { defaults.removeObject(forKey: key) }
        for (key, value) in savedDefaults { defaults.set(value, forKey: key) }
    }
    func packet(_ name: String, _ values: [String: Any]) -> Data {
        let record = TLRecord(function: name)
        for (key, value) in values { record[key] = value }
        record.normalizeOptionalFlags()
        return record.serializedData()!
    }
    let peer = Api.InputPeer.inputPeerUser(.init(userId: 456, accessHash: 1))
    defaults.set(true, forKey: "TGExtraGhostModeEnabled")
    defaults.set(true, forKey: "disableTypingStatus")
    defaults.set(true, forKey: "disableOnlineStatus")
    check(TLMethodID.messagesSendMedia.id == newer.functions["messages.sendMedia"]!.signature &&
          TLMethodID.messagesSendMedia.id != original.functions["messages.sendMedia"]!.signature, "Method IDs follow the host")
    let action = TLRecord(type: "SendMessageAction", constructor: "sendMessageTypingAction")
    let typing = packet("messages.setTyping", ["flags": Int32(0), "peer": peer.record, "action": action])
    check(TLParser.fakeResponseForPayload(typing as NSData) == serialized(Api.Bool.boolTrue),
          "Privacy survives changed method, peer, action and response IDs plus reordered fields")
    for length in 0..<typing.count {
        check(TLParser.fakeResponseForPayload(typing.prefix(length) as NSData) == nil, "Truncated future requests pass through")
    }
    var stale = typing
    var oldId = original.functions["messages.setTyping"]!.signature.littleEndian
    withUnsafeBytes(of: &oldId) { stale.replaceSubrange(0..<4, with: $0) }
    check(TLParser.fakeResponseForPayload(stale as NSData) == nil, "Old numeric IDs are not aliases")
    TGExtraTestSetGhostException(456, true)
    check(TLParser.fakeResponseForPayload(typing as NSData) == nil, "Exceptions survive changed peer IDs")
    TGExtraTestSetGhostException(456, false)

    let config = packet("help.getAppConfig", ["hash": Int32(123)])
    let refreshed = TLParser.rewriteAppConfigRequest(config as NSData)!
    check(newer.request(refreshed as Data)?["hash"] as? Int32 == 0, "Configuration refresh uses the host method")
    check(TLParser.privacyReplacementRequest() == packet("help.getNearestDc", [:]) as NSData,
          "Rust privacy replacement uses the host ID")

    defaults.set(true, forKey: "TGExtraVideoToVoice")
    TLParser.registerVoiceUpload(withFileName: "future.m4a", duration: 3, waveform: nil)
    let media = Api.InputMedia.inputMediaUploadedDocument(.init(flags: 0,
        file: .inputFile(.init(id: 1, parts: 1, name: "future.m4a", md5Checksum: "")), thumb: nil,
        mimeType: "audio/mp4", attributes: [.documentAttributeFilename(.init(fileName: "future.m4a"))],
        stickers: nil, videoCover: nil, videoTimestamp: nil, ttlSeconds: nil))
    let send = packet("messages.sendMedia", ["flags": Int32(0), "peer": peer.record, "media": media.record,
        "message": "caption", "randomId": Int64(123), "hash": Int32(789)])
    let voice = TLParser.rewriteVoiceUpload(send as NSData)!
    let rewritten = newer.request(voice as Data)!
    let rewrittenMedia = Api.InputMedia(rewritten["media"] as! TLRecord)!
    guard case let .inputMediaUploadedDocument(document) = rewrittenMedia,
          case .documentAttributeAudio = document.attributes.first else { fatalError("Expected voice") }
    check(rewritten["hash"] as? Int32 == 789 && rewritten["message"] as? String == "caption",
          "Voice rewriting preserves unknown required fields and caption")

    defaults.set(true, forKey: "TGExtraAntiSelfDestruct")
    let contents = packet("channels.readMessageContents", ["channel": Api.InputChannel.inputChannel(.init(channelId: 77, accessHash: 1)).record,
                                                           "id": [Int32(999)]])
    check(TLParser.readMessageContentsPolicy(contents as NSData, account: testAccount)?["response"] == serialized(Api.Bool.boolTrue),
          "Read privacy survives reordered channel/vector fields")
    let forward = Api.functions.messages.forwardMessages(flags: 1 << 10, fromPeer: peer, id: [1], randomId: [123],
        toPeer: peer, topMsgId: nil, replyTo: nil, scheduleDate: 1234, scheduleRepeatPeriod: nil, sendAs: nil,
        quickReplyShortcut: nil, effect: nil, videoTimestamp: nil, allowPaidStars: nil, suggestedPost: nil).1.makeValidData()!
    check(newer.request(forward)?["flags"] as? Int32 == 1 << 7 && ForwardCopyPlan(payload: forward) != nil,
          "Generated requests and protected-copy parsing resolve changed optional flag bits")
    defaults.set(true, forKey: "TGExtraDisableScreenshotNotification")
    let screenshot = packet("messages.sendScreenshotNotification", ["peer": peer.record,
        "replyTo": Api.InputReplyTo.inputReplyToMessage(.init(flags: 0, replyToMsgId: 1, topMsgId: nil, replyToPeerId: nil,
            quoteText: nil, quoteEntities: nil, quoteOffset: nil, monoforumPeerId: nil, todoItemId: nil, pollOption: nil, quoteRich: nil)).record,
        "randomId": Int64(1)])
    let updates = TLParser.fakeResponseForPayload(screenshot as NSData)!
    check((parsed(updates, as: Api.Updates.self).record["updates"] as? [TLRecord])?.isEmpty == true,
          "Screenshot replies use a complete host Updates response")
    defaults.set(true, forKey: "TGExtraAntiAutoDelete")
    func opaqueHistory(timed: Bool) -> NSData {
        let root = Api.messages.Messages.messages(.init(messages: [message(98765, ttl: timed ? 60 : nil)],
                                                       topics: [], chats: [], users: []))
        let buffer = Buffer(data: (serialized(root) as Data).dropLast(8))
        buffer.appendInt32(481674261); buffer.appendInt32(1)
        buffer.appendInt32(1234567); buffer.appendInt32(0)
        return buffer.makeData() as NSData
    }
    check(strip(opaqueHistory(timed: true)) == opaqueHistory(timed: false),
          "Opaque-peer fallback follows changed host container IDs and preserves the unknown suffix")
    let duplicate = functions + 28
    var invalid = image
    var duplicateId = UInt32(u32(functions + 4)).littleEndian
    withUnsafeBytes(of: &duplicateId) { invalid.replaceSubrange(duplicate + 4..<duplicate + 8, with: $0) }
    check(HostSchema(image: invalid) == nil, "Ambiguous function IDs reject the table")
    for i in 0..<u32(28) {
        let p = functions + i * 28
        if string(u32(p)) == "messages.setTyping" {
            image[fields + u32(p + 16) * 20 + 4] = 0
        }
    }
    HostSchema.testSchema = HostSchema(image: image)!
    check(TLParser.fakeResponseForPayload(typing as NSData) == nil,
          "A changed response type cannot receive an incompatible synthetic Bool")
    print("PASS future schema: changed IDs, reordered fields, exceptions, unknown required fields, optional flags and synthetic responses")
}
