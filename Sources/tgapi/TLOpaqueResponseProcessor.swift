import Foundation

extension TLParser {
    static func hasUnknownPeer(_ reader: BufferReader, length: Int,
                                       usersFirst: Bool, suffixBytes: Int) -> Bool {
        guard length - Int(reader.offset) >= 16 + suffixBytes else { return false }
        let peerOrder: [Bool] = [usersFirst, !usersFirst]
        for (index, isUsers) in peerOrder.enumerated() {
            let minimumSuffix = suffixBytes + (index == 0 ? 8 : 0)
            guard reader.readInt32() == 481674261,
                  let count = reader.readInt32(), count >= 0,
                  length - Int(reader.offset) >= minimumSuffix,
                  Int(count) <= (length - Int(reader.offset) - minimumSuffix) / 4 else { return false }
            for _ in 0..<count {
                guard let constructor = reader.readInt32() else { return false }
                if !Api.isKnownConstructor(constructor) { return true }
                guard let peer = Api.parse(reader, signature: constructor),
                      isUsers ? peer is Api.User : peer is Api.Chat else { return false }
            }
        }
        return false
    }

    private static func minimumWireSize(_ field: TLField, depth: Int = 0) -> Int? {
        guard depth < 16 else { return nil }
        if field.flagsIndex >= 0 { return 0 }
        switch field.kind {
        case 0, 4, 5: return 4
        case 1, 3: return 8
        case 2: return 32
        case 7: return field.boxedVector ? 8 : 4
        case 6:
            guard let schema = HostSchema.shared else { return nil }
            let constructors = schema.constructors.values.filter { $0.typeIndex == field.typeIndex }
            let sizes = constructors.compactMap { constructor -> Int? in
                let sizes = constructor.fields.map { minimumWireSize($0, depth: depth + 1) }
                guard sizes.allSatisfy({ $0 != nil }) else { return nil }
                return sizes.compactMap { $0 }.reduce(field.bare ? 0 : 4, +)
            }
            return sizes.min()
        default: return nil
        }
    }

    static func patchHistoryWithOpaquePeers(_ data: NSData, signature: Int32) -> NSData? {
        guard let schema = HostSchema.shared, let descriptor = schema.constructors[signature] else { return nil }
        let type = schema.types[descriptor.typeIndex]
        let supported = ["messages.Messages", "messages.Dialogs", "messages.PeerDialogs", "messages.DiscussionMessage",
                         "updates.Difference", "updates.ChannelDifference", "Updates"]
        guard supported.contains(type) else { return nil }
        let reader = BufferReader(Buffer(nsData: data))
        reader.skip(4)
        var values = [Any?](repeating: nil, count: descriptor.fields.count)
        var ranges = [String: Range<Int>]()
        var foundOpaquePeer = false
        for (index, field) in descriptor.fields.enumerated() {
            if field.flagsIndex >= 0 {
                guard let flags = values[field.flagsIndex] as? Int32 else { return nil }
                if flags & (1 << field.flagBit) == 0 { continue }
            }
            if ["users", "chats"].contains(field.name) {
                // Preserve the opaque suffix byte-for-byte. Only accept the two
                // adjacent peer vectors, with the host-defined minimum trailer.
                guard index + 1 < descriptor.fields.count else { return nil }
                let second = descriptor.fields[index + 1]
                guard Set([field.name, second.name]) == Set(["users", "chats"]),
                      [field, second].allSatisfy({ $0.kind == 7 && $0.boxedVector && $0.elementKind == 6 }) else { return nil }
                let sizes = descriptor.fields.dropFirst(index + 2).map { minimumWireSize($0) }
                guard sizes.allSatisfy({ $0 != nil }) else { return nil }
                foundOpaquePeer = hasUnknownPeer(reader, length: data.length, usersFirst: field.name == "users",
                                                 suffixBytes: sizes.compactMap { $0 }.reduce(0, +))
                break
            }
            let start = Int(reader.offset)
            guard let value = TLCodec.read(field, reader: reader, depth: 1) else { return nil }
            values[index] = value
            ranges[field.name] = start..<Int(reader.offset)
        }
        guard foundOpaquePeer else { return nil }
        MessagePatches.prepareDecodedObjects(in: reader)
        var replacements = [(Range<Int>, Data)]()
        var changed = false
        for name in ["messages", "newMessages"] {
            guard let index = descriptor.fieldIndices[name], let raw = values[index] as? [TLRecord],
                  let range = ranges[name] else { continue }
            let messages = raw.compactMap(Api.Message.init)
            guard messages.count == raw.count else { return nil }
            let batch = patchMessageBatch(messages, chats: [])
            changed = changed || batch.changed
            let buffer = Buffer()
            buffer.appendInt32(481674261); buffer.appendInt32(Int32(batch.messages.count))
            for message in batch.messages { message.serialize(buffer, true) }
            guard let encoded = buffer.makeValidData() else { return nil }
            replacements.append((range, encoded))
        }
        for name in ["updates", "otherUpdates"] {
            guard let index = descriptor.fieldIndices[name], let raw = values[index] as? [TLRecord],
                  let range = ranges[name] else { continue }
            let updates = raw.compactMap(Api.Update.init)
            guard updates.count == raw.count else { return nil }
            let (patched, modified) = stripTTLUpdates(updates)
            changed = changed || modified
            let buffer = Buffer()
            buffer.appendInt32(481674261); buffer.appendInt32(Int32(patched.count))
            for update in patched { update.serialize(buffer, true) }
            guard let encoded = buffer.makeValidData() else { return nil }
            replacements.append((range, encoded))
        }
        guard MessagePatches.shouldReserialize(changed: changed, settings: packetSettings) else { return reader.dataApplyingPatches() }
        return reader.dataApplyingPatches(replacing: replacements)
    }
}
