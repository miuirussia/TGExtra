import Foundation
import CryptoKit

// This is TGExtra's own protocol bridge. It never calls or patches Swift code
// in the host app; MTRequest carries boxed TL data across the ObjC boundary.
@objc(TGExtraForwardCopyPlan)
final class ForwardCopyPlan: NSObject {
    private let flags: Int32
    private let source: Api.InputPeer
    private let destination: Api.InputPeer
    private let ids: [Int32]
    private let randomIds: [Int64]
    private let topId: Int32?
    private let reply: Api.InputReplyTo?
    private let schedule: Int32?
    private let sendAs: Api.InputPeer?
    private let paidStars: Int64?
    private let originalPayload: Data
    private var items = [Item]()
    private var batches = [[Int64]]()
    private var users = [Int64: Api.InputUser]()
    @objc private(set) var errorDescription = "TGEXTRA_COPY_UNSUPPORTED"
    @objc private(set) var downloads = [[String: Any]]()
    @objc private(set) var requests = [[String: Any]]()

    private struct Item {
        let message: Api.Message.Cons_message
        let location: Api.InputFileLocation?
        let size: Int64
        let dc: Int32
        let photo: Bool
        let mime: String
        let attributes: [Api.DocumentAttribute]
        let spoiler: Bool
        var media: Api.InputMedia?
    }

    private static func boxed<T>(_ bytes: Data, as type: T.Type) -> T? {
        let reader = BufferReader(Buffer(data: bytes))
        guard let signature = reader.readInt32(), let value = Api.parse(reader, signature: signature) as? T,
              reader.offset == UInt(bytes.count) else { return nil }
        return value
    }

    private static func bytes(_ value: TypeConstructorDescription) -> Data {
        let buffer = Buffer()
        Api.serializeObject(value, buffer: buffer, boxed: true)
        return buffer.makeData()
    }

    @objc(initWithPayload:)
    init?(payload: Data) {
        let reader = BufferReader(Buffer(data: payload))
        guard reader.readInt32() == 326126204, let flags = reader.readInt32() else { return nil }
        // Unsupported forward semantics must not silently turn into a different
        // send (quick replies, ephemeral sources, effects, suggested posts, etc.).
        let supported: Int32 = [5, 6, 8, 9, 10, 11, 12, 13, 14, 19, 21, 22].reduce(0) { $0 | (1 << $1) }
        guard flags & ~supported == 0 else { return nil }
        func peer() -> Api.InputPeer? {
            guard let signature = reader.readInt32() else { return nil }
            return Api.parse(reader, signature: signature) as? Api.InputPeer
        }
        guard let source = peer(), reader.readInt32() == 481674261,
              let count = reader.readInt32(), count > 0, count <= 100,
              payload.count >= Int(count) * 12 + 24 else { return nil }
        var ids = [Int32]()
        for _ in 0..<count {
            guard let id = reader.readInt32(), id > 0 else { return nil }
            ids.append(id)
        }
        guard reader.readInt32() == 481674261, reader.readInt32() == count else { return nil }
        var randomIds = [Int64]()
        for _ in 0..<count {
            guard let id = reader.readInt64(), id != 0 else { return nil }
            randomIds.append(id)
        }
        guard Set(ids).count == ids.count, Set(randomIds).count == randomIds.count,
              let destination = peer() else { return nil }
        let topId = flags & (1 << 9) != 0 ? reader.readInt32() : nil
        if flags & (1 << 9) != 0 && topId == nil { return nil }
        var reply: Api.InputReplyTo?
        if flags & (1 << 22) != 0 {
            guard let signature = reader.readInt32(),
                  let value = Api.parse(reader, signature: signature) as? Api.InputReplyTo else { return nil }
            reply = value
        }
        // A topic is represented by reply_to on the send methods, rather than
        // forwardMessages.top_msg_id. Do not discard an explicit reply.
        if let topId = topId {
            if case let .inputReplyToMessage(value)? = reply {
                value.flags |= 1
                value.topMsgId = topId
            } else if reply == nil {
                reply = .inputReplyToMessage(.init(flags: 1, replyToMsgId: topId, topMsgId: topId,
                    replyToPeerId: nil, quoteText: nil, quoteEntities: nil, quoteOffset: nil,
                    monoforumPeerId: nil, todoItemId: nil, pollOption: nil))
            } else { return nil }
        }
        let schedule = flags & (1 << 10) != 0 ? reader.readInt32() : nil
        if flags & (1 << 10) != 0 && schedule == nil { return nil }
        let sendAs = flags & (1 << 13) != 0 ? peer() : nil
        if flags & (1 << 13) != 0 && sendAs == nil { return nil }
        let paid = flags & (1 << 21) != 0 ? reader.readInt64() : nil
        if flags & (1 << 21) != 0 && paid == nil { return nil }
        guard reader.offset == UInt(payload.count) else { return nil }
        self.flags = flags; self.source = source; self.destination = destination
        self.ids = ids; self.randomIds = randomIds; self.topId = topId
        self.reply = reply; self.schedule = schedule; self.sendAs = sendAs; self.paidStars = paid
        self.originalPayload = payload
        super.init()
    }

    @objc(operationKeyForAccount:payload:)
    static func operationKey(account: String, payload: Data) -> String {
        var data = Data(account.utf8); data.append(0); data.append(payload)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func getMessages(peer: Api.InputPeer, ids: [Int32]) -> Data? {
        let input = ids.map { Api.InputMessage.inputMessageID(.init(id: $0)) }
        switch peer {
        case let .inputPeerChannel(value):
            return Api.functions.channels.getMessages(channel: .inputChannel(.init(channelId: value.channelId,
                accessHash: value.accessHash)), id: input).1.makeData()
        case .inputPeerSelf, .inputPeerUser, .inputPeerChat:
            return Api.functions.messages.getMessages(id: input).1.makeData()
        default: return nil
        }
    }

    @objc var sourceRequest: Data? { Self.getMessages(peer: source, ids: ids) }

    private static func messages(_ bytes: Data) -> (messages: [Api.Message], users: [Api.User], chats: [Api.Chat])? {
        guard let result = boxed(bytes, as: Api.messages.Messages.self) else { return nil }
        switch result {
        case let .messages(value): return (value.messages, value.users, value.chats)
        case let .messagesSlice(value): return (value.messages, value.users, value.chats)
        case let .channelMessages(value): return (value.messages, value.users, value.chats)
        default: return nil
        }
    }

    private static func matches(_ peer: Api.Peer, input: Api.InputPeer) -> Bool {
        switch (peer, input) {
        case let (.peerChannel(p), .inputPeerChannel(i)): return p.channelId == i.channelId
        case let (.peerChat(p), .inputPeerChat(i)): return p.chatId == i.chatId
        case let (.peerUser(p), .inputPeerUser(i)): return p.userId == i.userId
        case (.peerUser, .inputPeerSelf): return true // getMessages returns only the requested IDs.
        default: return false
        }
    }

    @objc(prepareWithResponse:)
    func prepare(response: Data) -> Bool {
        items.removeAll(); downloads.removeAll(); requests.removeAll(); batches.removeAll()
        users.removeAll()
        guard let result = Self.messages(response) else { return fail("TGEXTRA_COPY_SOURCE_INVALID") }
        for user in result.users {
            if case let .user(value) = user {
                if value.flags & (1 << 10) != 0 { users[value.id] = .inputUserSelf }
                else if let hash = value.accessHash { users[value.id] = .inputUser(.init(userId: value.id, accessHash: hash)) }
            }
        }
        var byId = [Int32: Api.Message.Cons_message]()
        for message in result.messages {
            if case let .message(value) = message, Self.matches(value.peerId, input: source) {
                guard byId[value.id] == nil else { return fail("TGEXTRA_COPY_SOURCE_INVALID") }
                byId[value.id] = value
            }
        }
        for id in ids {
            guard let message = byId[id], message.richMessage == nil else { return fail("TGEXTRA_COPY_SOURCE_UNAVAILABLE") }
            var item = Item(message: message, location: nil, size: 0, dc: 0, photo: false,
                            mime: "", attributes: [], spoiler: false, media: nil)
            switch message.media {
            case nil, .messageMediaEmpty?, .messageMediaWebPage?:
                guard !message.message.isEmpty else { return fail("TGEXTRA_COPY_UNSUPPORTED") }
            case let .messageMediaPhoto(media)?:
                guard media.ttlSeconds == nil, media.video == nil, case let .photo(photo)? = media.photo else { return fail("TGEXTRA_COPY_UNSUPPORTED") }
                var sizes = [(type: String, size: Int64, area: Int64)]()
                for size in photo.sizes {
                    switch size {
                    case let .photoSize(s): sizes.append((s.type, Int64(s.size), Int64(s.w) * Int64(s.h)))
                    case let .photoSizeProgressive(s):
                        if let bytes = s.sizes.max() { sizes.append((s.type, Int64(bytes), Int64(s.w) * Int64(s.h))) }
                    default: break
                    }
                }
                guard let size = sizes.max(by: { $0.area < $1.area }), size.size > 0 else { return fail("TGEXTRA_COPY_UNSUPPORTED") }
                item = Item(message: message, location: .inputPhotoFileLocation(.init(id: photo.id,
                    accessHash: photo.accessHash, fileReference: photo.fileReference, thumbSize: size.type)),
                    size: size.size, dc: photo.dcId, photo: true, mime: "image/jpeg", attributes: [],
                    spoiler: media.flags & (1 << 3) != 0, media: nil)
            case let .messageMediaDocument(media)?:
                guard media.ttlSeconds == nil, case let .document(document)? = media.document,
                      document.size > 0 else { return fail("TGEXTRA_COPY_UNSUPPORTED") }
                for attribute in document.attributes {
                    switch attribute {
                    case .documentAttributeSticker, .documentAttributeCustomEmoji: return fail("TGEXTRA_COPY_UNSUPPORTED")
                    default: break
                    }
                }
                item = Item(message: message, location: .inputDocumentFileLocation(.init(id: document.id,
                    accessHash: document.accessHash, fileReference: document.fileReference, thumbSize: "")),
                    size: document.size, dc: document.dcId, photo: false, mime: document.mimeType,
                    attributes: document.attributes, spoiler: media.flags & (1 << 4) != 0, media: nil)
            default: return fail("TGEXTRA_COPY_UNSUPPORTED")
            }
            // 4000 parts at 512 KiB is the non-Premium upload ceiling. Larger
            // uploads need account-specific limits and are left to the host.
            if item.location != nil {
                guard item.dc > 0, item.size <= 4000 * 524288 else { return fail("TGEXTRA_COPY_FILE_TOO_LARGE") }
                downloads.append(["index": items.count, "dc": item.dc, "size": item.size])
            }
            items.append(item)
        }
        if paidStars != nil && items.count > 1 {
            guard flags & (1 << 8) != 0, items.count <= 10, let group = items.first?.message.groupedId,
                  items.allSatisfy({ $0.location != nil && $0.message.groupedId == group }) else {
                return fail("TGEXTRA_COPY_UNSUPPORTED_PAID_BATCH")
            }
        }
        return true
    }

    private func fail(_ reason: String) -> Bool { errorDescription = reason; return false }

    @objc(downloadRequestForIndex:offset:)
    func downloadRequest(index: Int, offset: Int64) -> Data? {
        guard items.indices.contains(index), let location = items[index].location, offset >= 0,
              offset < items[index].size, offset % 524288 == 0 else { return nil }
        return Api.functions.upload.getFile(flags: 0, location: location, offset: offset, limit: 524288).1.makeData()
    }

    @objc(refreshDownloadWithResponse:index:)
    func refreshDownload(response: Data, index: Int) -> Bool {
        guard items.indices.contains(index), let fresh = ForwardCopyPlan(payload: originalPayload),
              fresh.prepare(response: response), fresh.items.count == items.count else { return false }
        let old = items[index], new = fresh.items[index]
        guard old.size == new.size, old.dc == new.dc else { return false }
        switch (old.location, new.location) {
        case let (.inputDocumentFileLocation(a)?, .inputDocumentFileLocation(b)?):
            guard a.id == b.id, a.accessHash == b.accessHash else { return false }
        case let (.inputPhotoFileLocation(a)?, .inputPhotoFileLocation(b)?):
            guard a.id == b.id, a.accessHash == b.accessHash, a.thumbSize == b.thumbSize else { return false }
        default: return false
        }
        items[index] = Item(message: old.message, location: new.location, size: old.size, dc: old.dc,
            photo: old.photo, mime: old.mime, attributes: old.attributes, spoiler: old.spoiler, media: old.media)
        return true
    }

    @objc(fileBytesFromResponse:)
    static func fileBytes(response: Data) -> Data? {
        guard let result = boxed(response, as: Api.upload.File.self), case let .file(value) = result else { return nil }
        return value.bytes.makeData()
    }

    @objc(uploadRequestForFileId:part:total:bytes:big:)
    static func uploadRequest(fileId: Int64, part: Int32, total: Int32, bytes: Data, big: Bool) -> Data? {
        guard total > 0, total <= 4000, part >= 0, part < total, !bytes.isEmpty, bytes.count <= 524288 else { return nil }
        if big { return Api.functions.upload.saveBigFilePart(fileId: fileId, filePart: part,
            fileTotalParts: total, bytes: Buffer(data: bytes)).1.makeData() }
        return Api.functions.upload.saveFilePart(fileId: fileId, filePart: part, bytes: Buffer(data: bytes)).1.makeData()
    }

    @objc(isUploadAcknowledged:)
    static func isUploadAcknowledged(_ response: Data) -> Bool {
        guard let result = boxed(response, as: Api.Bool.self), case .boolTrue = result else { return false }
        return true
    }

    @objc(mediaUploadRequestForIndex:fileId:parts:md5:)
    func mediaUploadRequest(index: Int, fileId: Int64, parts: Int32, md5: String) -> Data? {
        guard items.indices.contains(index), items[index].location != nil, parts > 0 else { return nil }
        let item = items[index]
        let name = item.photo ? "photo.jpg" : item.attributes.compactMap { attribute -> String? in
            if case let .documentAttributeFilename(value) = attribute { return value.fileName }; return nil
        }.first ?? "file"
        let file: Api.InputFile = item.size > 10 * 1024 * 1024
            ? .inputFileBig(.init(id: fileId, parts: parts, name: name))
            : .inputFile(.init(id: fileId, parts: parts, name: name, md5Checksum: md5))
        let media: Api.InputMedia
        if item.photo {
            media = .inputMediaUploadedPhoto(.init(flags: item.spoiler ? 4 : 0, file: file,
                stickers: nil, ttlSeconds: nil, video: nil))
        } else {
            media = .inputMediaUploadedDocument(.init(flags: item.spoiler ? 32 : 0, file: file, thumb: nil,
                mimeType: item.mime, attributes: item.attributes, stickers: nil, videoCover: nil,
                videoTimestamp: nil, ttlSeconds: nil))
        }
        return Api.functions.messages.uploadMedia(flags: 0, businessConnectionId: nil, peer: destination, media: media).1.makeData()
    }

    @objc(registerMediaResponse:index:)
    func registerMedia(response: Data, index: Int) -> Bool {
        guard items.indices.contains(index), let media = Self.boxed(response, as: Api.MessageMedia.self) else { return false }
        let spoiler = items[index].spoiler
        switch media {
        case let .messageMediaPhoto(value):
            guard items[index].photo, case let .photo(photo)? = value.photo else { return false }
            items[index].media = .inputMediaPhoto(.init(flags: spoiler ? 2 : 0,
                id: .inputPhoto(.init(id: photo.id, accessHash: photo.accessHash, fileReference: photo.fileReference)), ttlSeconds: nil, video: nil))
        case let .messageMediaDocument(value):
            guard !items[index].photo, case let .document(document)? = value.document else { return false }
            items[index].media = .inputMediaDocument(.init(flags: spoiler ? 4 : 0,
                id: .inputDocument(.init(id: document.id, accessHash: document.accessHash, fileReference: document.fileReference)),
                videoCover: nil, videoTimestamp: nil, ttlSeconds: nil, query: nil))
        default: return false
        }
        return true
    }

    @objc func buildRequests() -> Bool {
        requests.removeAll(); batches.removeAll()
        guard items.count == ids.count, items.allSatisfy({ $0.location == nil || $0.media != nil }) else { return false }
        var index = 0
        while index < items.count {
            var end = index + 1
            if flags & (1 << 8) != 0, let group = items[index].message.groupedId, items[index].media != nil {
                while end < items.count, end - index < 10,
                      items[end].message.groupedId == group, items[end].media != nil { end += 1 }
            }
            var sendFlags = flags & ((1 << 5) | (1 << 6) | (1 << 10) | (1 << 13) | (1 << 14) | (1 << 19) | (1 << 21))
            if reply != nil { sendFlags |= 1 }
            let batchIds = Array(randomIds[index..<end])
            let payload: Data
            if end - index > 1 {
                let media: [Api.InputSingleMedia] = (index..<end).map { i in
                    let hide = flags & (1 << 12) != 0
                    let entities = hide ? nil : outgoingEntities(items[i].message)
                    return .inputSingleMedia(.init(flags: entities == nil ? 0 : 1, media: items[i].media!,
                        randomId: randomIds[i], message: hide ? "" : items[i].message.message, entities: entities))
                }
                payload = Api.functions.messages.sendMultiMedia(flags: sendFlags, peer: destination, replyTo: reply,
                    multiMedia: media, scheduleDate: schedule, sendAs: sendAs, quickReplyShortcut: nil,
                    effect: nil, allowPaidStars: paidStars).1.makeData()
            } else {
                let item = items[index]
                let hide = item.media != nil && flags & (1 << 12) != 0
                let entities = hide ? nil : outgoingEntities(item.message)
                if entities != nil { sendFlags |= 1 << 3 }
                // Preserve caption placement; flag 16 has the same meaning on
                // sendMessage and sendMedia, but isn't a forward option.
                if item.message.flags & (1 << 27) != 0 { sendFlags |= 1 << 16 }
                if let media = item.media {
                    payload = Api.functions.messages.sendMedia(flags: sendFlags, peer: destination, replyTo: reply,
                        media: media, message: hide ? "" : item.message.message, randomId: randomIds[index],
                        replyMarkup: nil, entities: entities, scheduleDate: schedule, scheduleRepeatPeriod: nil,
                        sendAs: sendAs, quickReplyShortcut: nil, effect: nil, allowPaidStars: paidStars, suggestedPost: nil).1.makeData()
                } else {
                    payload = Api.functions.messages.sendMessage(flags: sendFlags, peer: destination, replyTo: reply,
                        message: item.message.message, randomId: randomIds[index], replyMarkup: nil, entities: entities,
                        scheduleDate: schedule, scheduleRepeatPeriod: nil, sendAs: sendAs, quickReplyShortcut: nil,
                        effect: nil, allowPaidStars: paidStars, suggestedPost: nil, richMessage: nil).1.makeData()
                }
            }
            requests.append(["payload": payload, "randomIds": batchIds]); batches.append(batchIds)
            index = end
        }
        // A paid allowance applies to the original RPC as a whole. Splitting
        // it must not multiply the amount authorized by the user.
        if paidStars != nil && requests.count > 1 { requests.removeAll(); batches.removeAll(); return fail("TGEXTRA_COPY_UNSUPPORTED_PAID_BATCH") }
        return true
    }

    private func outgoingEntities(_ message: Api.Message.Cons_message) -> [Api.MessageEntity]? {
        return message.entities?.map { entity in
            if case let .messageEntityMentionName(value) = entity {
                let user = users[value.userId] ?? .inputUserFromMessage(.init(peer: source, msgId: message.id, userId: value.userId))
                return .inputMessageEntityMentionName(.init(offset: value.offset, length: value.length, userId: user))
            }
            return entity
        }
    }

    @objc(restoreRequests:)
    func restoreRequests(_ saved: [[String: Any]]) -> Bool {
        guard !saved.isEmpty, saved.count <= ids.count else { return false }
        var restored = [[Int64]]()
        for request in saved {
            guard let payload = request["payload"] as? Data, payload.count >= 4,
                  let ids = request["randomIds"] as? [Int64], !ids.isEmpty else { return false }
            restored.append(ids)
        }
        guard restored.flatMap({ $0 }) == randomIds else { return false }
        batches = restored; requests = saved
        return true
    }

    @objc(confirmationRequestForResponse:)
    func confirmationRequest(response: Data) -> Data? {
        guard let updates = Self.boxed(response, as: Api.Updates.self), case let .updateShortSentMessage(value) = updates else { return nil }
        return Self.getMessages(peer: destination, ids: [value.id])
    }

    @objc(normalizeResponse:confirmation:batch:)
    func normalize(response: Data, confirmation: Data?, batch: Int) -> Data? {
        guard batches.indices.contains(batch), let result = Self.boxed(response, as: Api.Updates.self) else { return nil }
        var updates: [Api.Update]; var users: [Api.User]; var chats: [Api.Chat]; let date: Int32
        switch result {
        case let .updates(value): updates = value.updates; users = value.users; chats = value.chats; date = value.date
        case let .updatesCombined(value): updates = value.updates; users = value.users; chats = value.chats; date = value.date
        case let .updateShort(value): updates = [value.update]; users = []; chats = []; date = value.date
        case let .updateShortSentMessage(value):
            guard batches[batch].count == 1, let confirmation = confirmation, let messages = Self.messages(confirmation),
                  let message = messages.messages.first(where: {
                      if case let .message(m) = $0 { return m.id == value.id && Self.matches(m.peerId, input: destination) }; return false
                  }) else { return nil }
            let update: Api.Update
            if case .inputPeerChannel = destination {
                update = .updateNewChannelMessage(.init(message: message, pts: value.pts, ptsCount: value.ptsCount))
            } else { update = .updateNewMessage(.init(message: message, pts: value.pts, ptsCount: value.ptsCount)) }
            updates = [.updateMessageID(.init(id: value.id, randomId: batches[batch][0])), update]
            users = messages.users; chats = messages.chats; date = value.date
        default: return nil
        }
        var mappings = [Int64: Int32](); var sent = Set<Int32>()
        for update in updates {
            switch update {
            case let .updateMessageID(value):
                if let previous = mappings[value.randomId], previous != value.id { return nil }
                mappings[value.randomId] = value.id
            case let .updateNewMessage(value):
                if case let .message(m) = value.message, Self.matches(m.peerId, input: destination) { sent.insert(m.id) }
            case let .updateNewChannelMessage(value):
                if case let .message(m) = value.message, Self.matches(m.peerId, input: destination) { sent.insert(m.id) }
            case let .updateNewScheduledMessage(value):
                if case let .message(m) = value.message, Self.matches(m.peerId, input: destination) { sent.insert(m.id) }
            default: break
            }
        }
        guard batches[batch].allSatisfy({ mappings[$0].map(sent.contains) == true }) else { return nil }
        // seq=0 is an unordered Updates envelope. Retain every real update's
        // pts/pts_count; never invent synchronization counters or message IDs.
        return Self.bytes(Api.Updates.updates(.init(updates: updates, users: users, chats: chats, date: date, seq: 0)))
    }

    @objc(mergeResponses:)
    static func mergeResponses(_ responses: [Data]) -> Data? {
        guard !responses.isEmpty else { return nil }
        var updates = [Api.Update](), users = [Api.User](), chats = [Api.Chat](); var date: Int32 = 0
        for bytes in responses {
            guard let response = boxed(bytes, as: Api.Updates.self), case let .updates(value) = response else { return nil }
            updates += value.updates; users += value.users; chats += value.chats; date = max(date, value.date)
        }
        return Self.bytes(Api.Updates.updates(.init(updates: updates, users: users, chats: chats, date: date, seq: 0)))
    }
}
