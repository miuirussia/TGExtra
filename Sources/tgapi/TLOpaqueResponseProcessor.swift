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

    static func patchHistoryWithOpaquePeers(_ data: NSData, signature: Int32) -> NSData? {
        let reader = BufferReader(Buffer(nsData: data))
        reader.skip(4)

        func object<T>(_ type: T.Type) -> T? {
            guard let constructor = reader.readInt32() else { return nil }
            return Api.parse(reader, signature: constructor) as? T
        }
        func vector<T>(_ type: T.Type) -> [T]? {
            guard reader.readInt32() == 481674261,
                  let count = reader.readInt32(), count >= 0,
                  Int(count) <= (data.length - Int(reader.offset)) / 4 else { return nil }
            var values = [T]()
            for _ in 0..<count {
                guard let value = object(type) else { return nil }
                values.append(value)
            }
            return values
        }

        var flags: Int32 = 0
        var hasTopics = false
        var hasUpdates = false
        var hasEncrypted = false
        var suffixBytes = 0
        switch signature {
        case 494135274: // messages.messages
            hasTopics = true
        case -948520370, 1595959062: // channelMessages, messagesSlice
            guard let value = reader.readInt32(), reader.readInt32() != nil else { return nil }
            flags = value
            if signature == -948520370 {
                guard reader.readInt32() != nil else { return nil } // count (after pts)
            } else if flags & (1 << 0) != 0 {
                guard reader.readInt32() != nil else { return nil } // next_rate
            }
            if flags & (1 << 2) != 0 {
                guard reader.readInt32() != nil else { return nil }
            }
            if signature == 1595959062 && flags & (1 << 3) != 0 {
                guard object(Api.SearchPostsFlood.self) != nil else { return nil }
            }
            hasTopics = true
        case 364538944, 1910543603, 863093588: // dialogs, dialogsSlice, peerDialogs
            if signature == 1910543603 {
                guard reader.readInt32() != nil else { return nil }
            }
            guard vector(Api.Dialog.self) != nil else { return nil }
            if signature == 863093588 { suffixBytes = 24 } // updates.State
        case -1506535550: // discussionMessage
            guard let value = reader.readInt32() else { return nil }
            flags = value
        case 543450958: // channelDifference
            guard let value = reader.readInt32(), reader.readInt32() != nil else { return nil }
            if value & (1 << 1) != 0 {
                guard reader.readInt32() != nil else { return nil }
            }
            hasUpdates = true
        case -1531132162: // channelDifferenceTooLong
            guard let value = reader.readInt32() else { return nil }
            if value & (1 << 1) != 0 {
                guard reader.readInt32() != nil else { return nil }
            }
            guard object(Api.Dialog.self) != nil else { return nil }
        case 16030880, -1459938943: // difference, differenceSlice
            hasEncrypted = true
            hasUpdates = true
            suffixBytes = 24
        default:
            return nil
        }

        let messageStart = Int(reader.offset)
        guard let messages = vector(Api.Message.self) else { return nil }
        let messageEnd = Int(reader.offset)
        if hasTopics {
            guard vector(Api.ForumTopic.self) != nil else { return nil }
        }
        if hasEncrypted {
            guard vector(Api.EncryptedMessage.self) != nil else { return nil }
        }
        var updates = [Api.Update]()
        let updateStart = Int(reader.offset)
        var updateEnd = updateStart
        if hasUpdates {
            guard let values = vector(Api.Update.self) else { return nil }
            updates = values
            updateEnd = Int(reader.offset)
        }
        if signature == -1506535550 {
            for bit in 0...2 where flags & (1 << bit) != 0 {
                guard reader.readInt32() != nil else { return nil }
            }
            guard reader.readInt32() != nil else { return nil } // unread_count
        }
        guard hasUnknownPeer(reader, length: data.length, usersFirst: false,
                             suffixBytes: suffixBytes) else { return nil }
        MessagePatches.prepareDecodedObjects(in: reader)
        let batch = patchMessageBatch(messages, chats: [])
        let (patchedUpdates, changedUpdates) = stripTTLUpdates(updates)
        guard MessagePatches.shouldReserialize(changed: batch.changed || changedUpdates, settings: packetSettings) else {
            return reader.dataApplyingPatches()
        }
        func boxedVector(_ values: [Any]) -> Data? {
            let buffer = Buffer()
            buffer.appendInt32(481674261)
            buffer.appendInt32(Int32(values.count))
            for value in values { Api.serializeObject(value, buffer: buffer, boxed: true) }
            return buffer.makeValidData()
        }
        var replacements = [(Range<Int>, Data)]()
        guard let encodedMessages = boxedVector(batch.messages) else { return nil }
        replacements.append((messageStart..<messageEnd, encodedMessages))
        if hasUpdates {
            guard let encodedUpdates = boxedVector(patchedUpdates) else { return nil }
            replacements.append((updateStart..<updateEnd, encodedUpdates))
        }
        return reader.dataApplyingPatches(replacing: replacements)
    }

    static func patchUpdateVector(_ data: NSData, signature: Int32) -> NSData? {
        guard signature == 1957577280 || signature == 1918567619 else { return nil }
        let reader = BufferReader(Buffer(nsData: data))
        reader.skip(4)
        guard reader.readInt32() == 481674261,
              let count = reader.readInt32(), count >= 0,
              Int(count) <= (data.length - 12) / 4 else { return nil }

        var updates = [(update: Api.Update, start: Int, length: Int)]()
        for _ in 0..<count {
            let start = Int(reader.offset)
            guard let constructor = reader.readInt32(),
                  let update = Api.parse(reader, signature: constructor) as? Api.Update else {
                return nil
            }
            updates.append((update, start, Int(reader.offset) - start))
        }
        let tail = Int(reader.offset)
        let minimumTail = signature == 1918567619 ? 28 : 24
        guard data.length - tail >= minimumTail else { return nil }

        guard hasUnknownPeer(reader, length: data.length, usersFirst: true,
                             suffixBytes: signature == 1918567619 ? 12 : 8) else { return nil }
        MessagePatches.prepareDecodedObjects(in: reader)

        var replacements = [(Range<Int>, Data)]()
        for entry in updates {
            let (patched, changed) = stripTTLUpdate(entry.update)
            if MessagePatches.shouldReserialize(changed: changed, settings: packetSettings) {
                let encoded = serializeBoxed(patched)
                guard encoded.length >= 4 else { return nil }
                replacements.append((entry.start..<entry.start + entry.length, encoded as Data))
            }
        }
        return reader.dataApplyingPatches(replacing: replacements)
    }
}
