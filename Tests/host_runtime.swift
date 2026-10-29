import Foundation
import tgapiC
import TestSupport

func testMessagePatchSettings() {
    typealias Setting = MessagePatches.Setting
    let keys = Setting.allCases
    let saved = Dictionary(uniqueKeysWithValues: keys.compactMap { key in
        defaults.object(forKey: key.rawValue).map { (key.rawValue, $0) }
    })
    func select(_ enabled: [Setting]) {
        for key in keys { defaults.removeObject(forKey: key.rawValue) }
        for key in enabled { defaults.set(true, forKey: key.rawValue) }
    }
    defer {
        for key in keys {
            if let value = saved[key.rawValue] { defaults.set(value, forKey: key.rawValue) }
            else { defaults.removeObject(forKey: key.rawValue) }
        }
    }
    let voice = Api.DocumentAttribute.documentAttributeAudio(.init(flags: 1 << 10, duration: 3,
        title: nil, performer: nil, waveform: nil))
    func privateUser() -> TLRecord {
        let record = TLRecord(type: "UserFull", constructor: "userFull")
        record.set("flags2", Int32((1 << 23) | (1 << 24)))
        return record
    }
    func upload() -> TLRecord {
        let record = TLRecord(type: "InputMedia", constructor: "inputMediaUploadedDocument")
        record.set("attributes", [Api.DocumentAttribute.documentAttributeFilename(.init(fileName: "registered.m4a"))])
        return record
    }
    struct RuleCase {
        let setting: Setting
        let make: () -> TLRecord
        let apply: (TLRecord) -> Bool
    }
    let rules = [
        RuleCase(setting: .preventAutoDelete, make: { message(98100, ttl: 60).record },
                 apply: { MessagePatches.removeAutoDeleteTimer(from: $0) }),
        RuleCase(setting: .preventMediaSelfDestruct,
                 make: { Api.MessageMedia.messageMediaPhoto(.init(flags: 4, photo: nil, ttlSeconds: 60, video: nil)).record },
                 apply: { MessagePatches.removeMediaTimer(from: $0) }),
        RuleCase(setting: .bypassForwarding, make: {
            let value = message(98101)
            messageData(value).flags |= 1 << 26
            return value.record
        }, apply: { MessagePatches.removeForwardingProtection(from: $0) }),
        RuleCase(setting: .bypassPrivateCopy, make: privateUser,
                 apply: { MessagePatches.removePrivateCopyProtection(from: $0) }),
        RuleCase(setting: .videoToVoice, make: upload,
                 apply: { MessagePatches.replaceVoiceAttributes(in: $0, attributes: [voice], registeredUpload: true) }),
    ]
    // Each individual switch must activate its own rule, without activating
    // unrelated field transformations. Also exercise the all-off state.
    for active in [Optional<Setting>.none] + keys.map(Optional.some) {
        select(active.map { [$0] } ?? [])
        for rule in rules {
            let record = rule.make()
            let changed = rule.apply(record)
            check(changed == (active == rule.setting), "Only \(rule.setting.rawValue) activates this field rule")
            if changed {
                check(!record.changes.isEmpty && record.changes.allSatisfy { $0.rule == rule.setting.rawValue },
                      "Trace identifies the controlling setting")
            } else { check(record.changes.isEmpty, "Disabled rules record no field changes") }
        }
    }

    select([.preventMediaSelfDestruct])
    let compact = Api.Updates.updateShortMessage(.init(flags: 1 << 26, id: 98102, userId: 42,
        message: "Compact", pts: 1, ptsCount: 1, date: 0, fwdFrom: nil, viaBotId: nil,
        replyTo: nil, entities: nil, ttlPeriod: nil))
    check(MessagePatches.removeForwardingProtection(from: compact.record) &&
          compact.record.changes.last?.rule == Setting.preventMediaSelfDestruct.rawValue,
          "The compact-update forwarding exception explicitly belongs to AntiSelfDestruct")
    select([.preventAutoDelete])
    let compactTimer = Api.Updates.updateShortMessage(.init(flags: (1 << 25) | (1 << 5), id: 98103, userId: 42,
        message: "Timer", pts: 1, ptsCount: 1, date: 0, fwdFrom: nil, viaBotId: nil,
        replyTo: nil, entities: nil, ttlPeriod: 60))
    check(MessagePatches.removeAutoDeleteTimer(from: compactTimer.record) && compactTimer.record.value("flags") as Int32 == 0,
          "The compact timer rule clears its timer presence and media_unread together")
    let profileTimer = TLRecord(type: "UserFull", constructor: "userFull")
    profileTimer.set("flags", Int32(1 << 14))
    profileTimer.set("ttlPeriod", Int32(60))
    check(!MessagePatches.removeAutoDeleteTimer(from: profileTimer), "Message timer protection does not alter profile defaults")

    let classifications = [(false, false), (true, false), (false, true), (true, true)]
    let deletionCases: [([Setting], [Bool])] = [
        ([], [false, false, false, false]),
        ([.keepDeletedMessages], [true, true, true, true]),
        ([.preventMediaSelfDestruct], [false, true, false, true]),
        ([.preventAutoDelete], [false, false, true, true]),
        ([.preventMediaSelfDestruct, .preventAutoDelete], [false, true, true, true]),
    ]
    for (enabled, expected) in deletionCases {
        select(enabled)
        let settings = MessagePatches.Settings()
        let actual = classifications.map { settings.protectsDeletion(disappearing: $0.0, autoDelete: $0.1) }
        check(actual == expected, "Deletion settings respect timer classification and their OR condition")
    }
    select([.keepDeletedMessages])
    let deletion = Api.Update.updateDeleteMessages(.init(messages: [1, 2], pts: 12, ptsCount: 2))
    check(MessagePatches.replaceDeletionIds(in: deletion.record, keeping: [0, 2]) && deletion.record.value("pts") as Int32 == 12,
          "The deletion rule changes IDs while retaining synchronization counters")
    check(!MessagePatches.replaceDeletionIds(in: deletion.record, keeping: [0]), "Deletion rules cannot drop vector entries")
    let sent = TLRecord(type: "Update", constructor: "updateDeleteScheduledMessages")
    sent.set("messages", [Int32(1)])
    sent.set("sentMessages", [Int32(1)])
    check(!MessagePatches.replaceDeletionIds(in: sent, keeping: [0]), "Sent scheduled messages still leave the queue normally")

    select([.hideDisappearingLabel])
    let hidden = message(98104)
    messageData(hidden).flags |= 1 << 5
    MessagePatches.markDisappearingMessage(hidden, observedDisappearing: true)
    check(messageData(hidden).message == "Original 😀" && messageData(hidden).flags & (1 << 5) == 0,
          "Hiding the label does not disable unread-media protection")
    select([])
    let unmarked = message(98105)
    MessagePatches.markDisappearingMessage(unmarked, observedDisappearing: false)
    check(unmarked.record.changes.isEmpty, "A label requires a previously observed disappearing marker")
    MessagePatches.markDisappearingMessage(unmarked, observedDisappearing: true)
    check(messageData(unmarked).message.hasPrefix("dissapearing message "), "The label rule applies only in its explicit context")
    for text in ["⏱️ ", "⏱️ Hello", "⏱️ 👨‍👩‍👧‍👦 Привет"] {
        let original = message(98106, text: text)
        messageData(original).entities = [.messageEntityBold(.init(offset: 0, length: Int32(text.utf16.count)))]
        MessagePatches.markDisappearingMessage(original, observedDisappearing: true)
        let marked = messageData(original)
        check(marked.message == "dissapearing message " + text, "Labels preserve the complete Unicode caption")
        guard case let .messageEntityBold(entity) = marked.entities!.last! else { fatalError("Missing caption entity") }
        check(entity.offset == Int32("dissapearing message ".utf16.count) && entity.length == Int32(text.utf16.count), "Labels retain UTF-16 entity ranges")
    }
    check(!MessagePatches.shouldReserialize(changed: false) && MessagePatches.shouldReserialize(changed: true),
          "With forwarding bypass off, other changes control reserialization")
    select([.bypassForwarding])
    check(MessagePatches.shouldReserialize(changed: false), "Forwarding bypass explicitly forces reserialization")
    select([.videoToVoice])
    check(!MessagePatches.replaceVoiceAttributes(in: upload(), attributes: [voice], registeredUpload: false),
          "The voice setting requires an upload registered by the extraction pipeline")
    select([.hideMentionReads])
    check(!MessagePatches.Settings().filtersContentReceipts, "Mention privacy requires Ghost Mode")
    select([.ghostMode, .hideMentionReads])
    check(!MessagePatches.Settings().allowsContentReceipt(disappearing: false, mention: true, reaction: false,
        classified: true, ghostException: false), "Known mention receipts are suppressed by their enabled rule")
    check(MessagePatches.Settings().allowsContentReceipt(disappearing: false, mention: true, reaction: true,
        classified: true, ghostException: true), "Ghost exceptions can allow ordinary content receipts")
    select([.ghostMode, .hideMentionReads, .preventMediaSelfDestruct])
    check(!MessagePatches.Settings().allowsContentReceipt(disappearing: true, mention: true, reaction: true,
        classified: true, ghostException: true), "Disappearing-media protection takes priority over Ghost exceptions")
    print("PASS centralized setting rules: off/on isolation, contexts, deletion combinations, traces and unconditional preparation")
}

func testExplicitDataPatches() {
    flags()
    let photo = Api.MessageMedia.messageMediaPhoto(.init(flags: 1 << 2, photo: nil, ttlSeconds: 60, video: nil))
    let original = message(98020, ttl: 86400, media: photo)
    messageData(original).flags |= (1 << 26) | (1 << 22)
    messageData(original).restrictionReason = [.restrictionReason(.init(platform: "ios", reason: "appleterms", text: "Blocked"))]
    let bytes = serialized(original)

    func decode() -> (BufferReader, Api.Message) {
        let reader = BufferReader(Buffer(nsData: bytes))
        let message = Api.parse(reader, signature: reader.readInt32()!) as! Api.Message
        check(reader.remaining == 0, "Read the complete fixture before applying a rule")
        return (reader, message)
    }
    let (reader, decoded) = decode()
    check(serialized(decoded) == bytes && reader.changes.isEmpty && reader.wireEdits.isEmpty,
          "Decoding is pure, including protection flags and content restrictions")
    reader.replaceFlags(of: decoded.record, field: "flags")
    check(reader.wireEdits.isEmpty, "An unchanged flags word produces no byte edit")
    let record = decoded.record
    let patch = TLDataPatch(record)
    let oldFlags = messageData(decoded).flags
    check(patch.clearFlag(.noForwards), "An explicitly named flag can be cleared")
    check(patch.removeOptionalField("ttlPeriod"), "Remove the timer and its schema-defined presence bit")
    check(record.changes.map(\.description) == [
        "Message.message.noforwards: true → false [flags.26]",
        "Message.message.ttlPeriod: 86400 → absent [flags.25]",
    ], "Trace names each changed field, before/after values and its flag")
    check(messageData(decoded).flags == oldFlags & ~((1 << 26) | (1 << 25)),
          "Named patches preserve unrelated flags")
    check(messageData(decoded).ttlPeriod == nil, "The timer value is removed too")
    check(!patch.clearFlag(.noForwards) && !patch.removeOptionalField("ttlPeriod") && record.changes.count == 2,
          "Repeated patches do not invent changes")
    check(reader.dataApplyingPatches() == nil, "An object patch alone does not rewrite original bytes")

    let media = messageData(decoded).media!
    check(TLDataPatch(media.record).removeOptionalField("ttlSeconds"), "Remove an independent media timer")
    check(media.record.changes.last?.description == "MessageMedia.messageMediaPhoto.ttlSeconds: 60 → absent [flags.2]",
          "Media changes identify their own constructor and presence flag")
    check(reader.changes.count == 3, "Changes on nested objects can be inspected together")

    check(patch.setOptionalField("ttlPeriod", Int32(3600)), "Setting an optional field restores its presence bit")
    check(messageData(decoded).ttlPeriod == 3600 && messageData(decoded).flags & (1 << 25) != 0,
          "An optional value and its bit stay consistent")
    check(!patch.removeOptionalField("id") && !patch.removeOptionalField("unknownField") &&
          !patch.clearFlag(.noForwardsPeerEnabled), "Unsupported operations do not change other fields")
    let fullUser = TLRecord(type: "UserFull", constructor: "userFull")
    fullUser.set("flags", Int32((1 << 14) | 1))
    fullUser.set("ttlPeriod", Int32(120))
    check(TLDataPatch(fullUser).removeOptionalField("ttlPeriod") && fullUser.fields["flags"] as? Int32 == 1,
          "The same field name resolves to flags.14 on UserFull, not Message's flags.25")

    let (wireReader, prepared) = decode()
    MessagePatches.prepareDecodedObjects(in: wireReader)
    check(wireReader.wireEdits.map(\.path) == ["Message.message.flags", "Message.message.restrictionReason"],
          "Direct byte edits explicitly identify the flags and removed restriction vector")
    let wire = wireReader.dataApplyingPatches()!
    let actual = parsed(wire, as: Api.Message.self)
    check(messageData(actual).restrictionReason == nil && messageData(actual).flags & (1 << 26) != 0,
          "Content byte edits preserve forwarding protection in the original packet")
    check(messageData(prepared).flags & (1 << 26) == 0,
          "Compatibility preparation affects the decoded copy separately")
    let count = wireReader.changes.count
    MessagePatches.prepareDecodedObjects(in: wireReader)
    check(wireReader.changes.count == count && wireReader.dataApplyingPatches() == wire,
          "Rule preparation is idempotent in both object and byte forms")

    let truncated = BufferReader(Buffer(data: (bytes as Data).dropLast(4)))
    check(Api.parse(truncated, signature: truncated.readInt32()!) == nil && truncated.changes.isEmpty &&
          truncated.wireEdits.isEmpty, "An incomplete decode applies no rules")
    flags()
    print("PASS explicit patches: pure decoding, named flags, optional presence, readable traces and separate wire edits")
}

func testMissingHostSchema() {
    check(HostSchema.shared == nil, "Do not replace a missing host schema with a bundled protocol")
    flags("TGExtraAntiAutoDelete", "TGExtraAntiSelfDestruct", "TGExtraAntiRevoke", "disableForwardRestriction")
    let original = Buffer()
    original.appendInt32(Int32(bitPattern: 0x7600b9d3))
    original.appendInt32(0)
    original.appendInt32(0)
    original.appendInt32(98003)
    original.appendInt32(0x59511722)
    original.appendInt64(42)
    original.appendInt32(1234)
    serializeString("Original", buffer: original, boxed: false)
    check(strip(original.makeData() as NSData) == nil, "Keep the original response when no schema is available")
    let request = Buffer()
    request.appendInt32(0x61e3f854)
    request.appendInt32(1234)
    check(TLParser.rewriteAppConfigRequest(request.makeData() as NSData) == nil,
          "Do not emit an incomplete request without host metadata")
    check(TLMethodID.messagesForward.id == nil && TLParser.requestMethod(request.makeData() as NSData) == nil,
          "Missing schema cannot match an outgoing method")
    check(TLParser.emptyResponse(method: .messagesSendScreenshotNotification, constructor: "updates") == nil &&
          TLParser.privacyReplacementRequest() == nil, "No stale synthetic packets without host metadata")
    print("PASS missing host schema: original responses and unavailable request policies")
}

func testHostSchemaCodec() {
    flags()
    let schema = HostSchema.shared!
    check(schema.constructors.count == 1716 && schema.functions.count == 849, "Read the original host table")
    check(Api.isKnownConstructor(-1471112230), "A primitive in a peer vector is malformed, not an unknown peer")

    // This type has no generated view. Its wire order comes entirely from the host.
    let opaque = TLRecord(type: "help.TimezonesList", constructor: "timezonesList")
    opaque.set("timezones", [TLRecord]())
    opaque.set("hash", Int32(17))
    let bytes = Buffer()
    bytes.appendInt32(2071260529)
    bytes.appendInt32(481674261)
    bytes.appendInt32(0)
    bytes.appendInt32(17)
    check(serialized(opaque) == bytes.makeData() as NSData, "Serialize an unmodeled type using host field order")
    let reader = BufferReader(bytes)
    guard let decoded = Api.parse(reader, signature: reader.readInt32()!) as? TLRecord else {
        fatalError("Expected an unmodeled host object")
    }
    check(reader.remaining == 0 && serialized(decoded) == bytes.makeData() as NSData, "Unmodeled objects round-trip")

    let entityBytes = Buffer()
    entityBytes.appendInt32(106086853)
    entityBytes.appendInt32(1)
    entityBytes.appendInt32(2)
    let entity = parsed(entityBytes.makeData() as NSData, as: Api.MessageEntity.self)
    guard case .other = entity else { fatalError("Do not require generated views for every host constructor") }
    let nested = message(98001)
    messageData(nested).entities = [entity]
    let nestedBytes = serialized(nested)
    let reparsed = parsed(nestedBytes, as: Api.Message.self)
    check(serialized(reparsed) == nestedBytes, "Preserve unmodeled nested constructors")

    // Simulate a newer host adding a field that this build's view does not name.
    let original = message(98002, text: "Original")
    let descriptor = original.record.descriptor!
    let extra = TLField(name: "futureField", kind: 1, elementKind: 0, optional: false,
                        boxedVector: false, bare: false, flagsIndex: -1, flagBit: 0,
                        typeIndex: 0, constructorIndex: 0)
    let newer = TLConstructor(name: descriptor.name, signature: descriptor.signature,
                              typeIndex: descriptor.typeIndex, caseIndex: descriptor.caseIndex,
                              fields: descriptor.fields + [extra])
    let record = TLRecord(descriptor: newer, type: "Message")
    record.fields = original.record.fields
    record.set("futureField", Int64(0x123456789))
    let futureBytes = serialized(record)
    let futureReader = BufferReader(Buffer(nsData: futureBytes))
    _ = futureReader.readInt32()
    let future = TLCodec.parse(futureReader, descriptor: newer)!
    let view = Api.Message(future)!
    messageData(view).message = "Edited"
    messageData(original).message = "Edited"
    let expected = Buffer(nsData: serialized(original))
    expected.appendInt64(0x123456789)
    check(serialized(view) == expected.makeData() as NSData, "Known-field edits retain fields introduced by the host")
    let rebuilt = message(98002, text: "Rebuilt")
    rebuilt.record.retainUnwrittenFields(from: future)
    check(rebuilt.record.fields["futureField"] as? Int64 == 0x123456789,
          "Rebuilt containers keep fields unknown to their typed view")

    let invalid = TLRecord(type: "Message", constructor: "message")
    let invalidBuffer = Buffer()
    invalid.serialize(invalidBuffer, true)
    check(invalidBuffer.makeValidData() == nil && invalidBuffer.makeData().isEmpty,
          "Never emit a partly serialized request")

    let image = TGExtraHostTLSchema()!
    check(HostSchema(image: image) != nil, "Accept the original schema")
    check(HostSchema(image: image.prefix(71)) == nil, "Reject a truncated schema header")
    var corrupted = image
    corrupted[4] = 255
    check(HostSchema(image: corrupted) == nil, "Reject unsupported schema formats")
    corrupted = image
    corrupted.replaceSubrange(60..<64, with: [255, 255, 255, 127])
    check(HostSchema(image: corrupted) == nil, "Reject table offsets outside the image")
    print("PASS host-driven codec, unmodeled objects, future fields, invalid serialization and schema validation")
}

func testOptimizedWirePaths() {
    flags()
    let original = message(98200)
    let originalBytes = serialized(original)
    let reader = BufferReader(Buffer(nsData: originalBytes))
    let decoded = Api.parse(reader, signature: reader.readInt32()!) as! Api.Message
    check(decoded.record.hasCompatibleView, "Complete decoding uses the schema-validated view")
    check(decoded.record.wireSource?.isDirty == false && serialized(decoded) == originalBytes,
          "Unchanged objects serialize from their immutable packet")
    guard case let .messageEntityBold(entity) = messageData(decoded).entities![0] else { fatalError("Expected bold entity") }
    entity.offset = 3
    check(decoded.record.wireSource?.isDirty == true, "Nested setters invalidate ancestor byte copies")
    guard case let .messageEntityBold(expectedEntity) = messageData(original).entities![0] else { fatalError("Expected bold entity") }
    expectedEntity.offset = 3
    check(serialized(decoded) == serialized(original), "Nested edits survive root serialization")

    let independent = parsed(originalBytes, as: Api.Message.self)
    check(independent.record.wireSource?.isDirty == false, "Other packets keep their own mutation state")
    messageData(independent).record.set("message", Optional<String>.none)
    guard case .other = Api.Message(independent.record)! else { fatalError("Reject an invalidated required field") }
    check(serialized(independent).length == 0, "A mutated incomplete record cannot bypass validation")

    let file = Api.upload.File.file(.init(type: .fileUnknown, mtime: 0, bytes: Buffer(data: Data([1, 2, 3]))))
    let fileBytes = serialized(file)
    let parsedFile = parsed(fileBytes, as: Api.upload.File.self)
    guard case let .file(data) = parsedFile else { fatalError("Expected file") }
    check(parsedFile.record.wireSource?.canCopy == false, "Mutable byte buffers use value serialization")
    data.bytes.data!.storeBytes(of: UInt8(9), as: UInt8.self)
    let expectedFile = Api.upload.File.file(.init(type: .fileUnknown, mtime: 0, bytes: Buffer(data: Data([9, 2, 3]))))
    check(serialized(parsedFile) == serialized(expectedFile), "In-place Buffer edits are preserved")

    let descriptor = original.record.descriptor!
    let incompatibleFields = descriptor.fields.map { field -> TLField in
        guard field.name == "message" else { return field }
        return TLField(name: field.name, kind: 0, elementKind: 0, optional: false, boxedVector: false,
                       bare: false, flagsIndex: -1, flagBit: 0, typeIndex: 0, constructorIndex: 0)
    }
    let incompatible = TLConstructor(name: descriptor.name, signature: descriptor.signature,
        typeIndex: descriptor.typeIndex, caseIndex: descriptor.caseIndex, fields: incompatibleFields,
        type: "Message", types: HostSchema.shared!.types)
    check(!incompatible.supportsView, "A changed required field type cannot use cached view validation")
    let wrongType = TLRecord(descriptor: incompatible, type: "Message")
    wrongType.fields = original.record.fields
    wrongType.set("message", Int32(1))
    let wrongBytes = serialized(wrongType)
    let wrongReader = BufferReader(Buffer(nsData: wrongBytes))
    _ = wrongReader.readInt32()
    let wrongRecord = TLCodec.parse(wrongReader, descriptor: incompatible)!
    guard case .other = Api.Message(wrongRecord)! else { fatalError("Do not expose an incompatible host layout") }

    let snapshot = MessagePatches.Settings(snapshot: true)
    flags("TGExtraAntiAutoDelete")
    check(!snapshot.preventAutoDelete && MessagePatches.Settings().preventAutoDelete,
          "A packet snapshot stays stable while later operations see new settings")
    flags()
    print("PASS schema-validated views, nested byte-copy invalidation, mutable buffers and settings snapshots")
}

func testBufferAppends() {
    let left = Buffer(data: Data([1, 2]))
    let right = Buffer(data: Data([3, 4]))
    left.appendBuffer(right)
    check(left.makeData() == Data([1, 2, 3, 4]) && left.size == 4, "Buffer append retains all bytes and updates size")
    left.appendBuffer(Buffer())
    left.appendInt32(5)
    check(left.makeData().prefix(4) == Data([1, 2, 3, 4]) && left.size == 8, "A following write does not overwrite appended bytes")
    let growing = Buffer(data: Data(repeating: 42, count: 1024))
    growing.appendBuffer(growing)
    check(growing.makeData() == Data(repeating: 42, count: 2048), "Self-append survives realloc")
    let empty = Buffer()
    empty.appendBuffer(empty)
    check(empty.size == 0, "Empty self-append")
}

func testMarkerBatchPersistence() {
    flags("TGExtraAntiAutoDelete", "TGExtraAntiRevoke")
    let key = "TGExtraMessageMarkersByAccount"
    let before = TGExtraTestPreferenceWriteCount(key)
    let messages = (990_000..<990_020).map { message(Int32($0), ttl: 60) }
    let packet = Api.messages.Messages.messages(.init(messages: messages, topics: [], chats: [], users: []))
    _ = strip(serialized(packet), account: "account-marker-batch")
    check(TGExtraTestPreferenceWriteCount(key) == before + 1, "One timer packet persists all markers once")
    let saved = defaults.dictionary(forKey: key)!
    check(messages.allSatisfy { saved["account-marker-batch:0:\(messageData($0).id)"] as? Int == 4 },
          "The packet's markers are durable before parsing returns")
    let repeatCount = TGExtraTestPreferenceWriteCount(key)
    _ = strip(serialized(packet), account: "account-marker-batch")
    check(TGExtraTestPreferenceWriteCount(key) == repeatCount, "An unchanged packet does not rewrite markers")
    TLParser.addDeletedId(990_021, peer: 42, account: "account-marker-batch")
    check(TGExtraTestPreferenceWriteCount(key) == repeatCount + 1, "A standalone marker remains immediately durable")
    flags()
}
