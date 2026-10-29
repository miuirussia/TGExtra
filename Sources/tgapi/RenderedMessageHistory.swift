import Foundation

extension TLParser {
    typealias RenderedMessage = RenderedMessageReader.RenderedMessage

    @objc static func getMessageId(from item: Any) -> NSNumber? {
        return RenderedMessageReader.renderedMessages(from: item).first.map { NSNumber(value: $0.id) }
    }

    @objc static func getMessageIdFromNode(_ node: Any) -> NSNumber? {
        return RenderedMessageReader.renderedMessagesFromNode(node).first.map { NSNumber(value: $0.id) }
    }

    @objc static func getMessagePeerKeyFromNode(_ node: Any) -> NSNumber? {
        return RenderedMessageReader.renderedMessagesFromNode(node).first.map { NSNumber(value: $0.peer) }
    }

    @objc static func getMessageNamespaceFromNode(_ node: Any) -> NSNumber? {
        return RenderedMessageReader.renderedMessagesFromNode(node).first.map { NSNumber(value: $0.namespace) }
    }

    @objc(messageStateFromNode:observe:) static func messageState(from node: Any, observe: Bool) -> [String: Any]? {
        guard let item = HostValueReader.storedField("item", in: node) else { return nil }
        let messages = RenderedMessageReader.renderedMessages(from: item)
        guard let first = messages.first, let account = HostAccountReader.account(in: item, depth: 0) else { return nil }
        if observe {
            for message in messages {
                recordRenderedMessage(message, account: account)
            }
        }
        return ["id": NSNumber(value: first.id), "peer": NSNumber(value: first.peer),
                "namespace": NSNumber(value: first.namespace), "account": account]
    }

    @objc static func hasAdMessageFromNode(_ node: Any) -> Bool {
        return RenderedMessageReader.renderedMessagesFromNode(node).contains { message in
            let attributes = HostValueReader.storedField("attributes", in: message.value) as? [Any] ?? []
            return attributes.contains { String(reflecting: type(of: $0)).split(separator: ".").last == "AdMessageAttribute" }
        }
    }

    struct EntityValue: Encodable {
        let value: Encodable
        func encode(to encoder: Encoder) throws { try value.encode(to: encoder) }
    }

    static func storedEntities(_ values: [Any]) -> Data? {
        let buffer = Buffer()
        for value in values {
            guard let value = value as? Encodable,
                  let data = try? JSONEncoder().encode(EntityValue(value: value)),
                  let fields = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let kind = fields["_rawValue"] as? NSNumber,
                  let start = fields["start"] as? NSNumber, let end = fields["end"] as? NSNumber,
                  let offset = Int32(exactly: start.int64Value),
                  let endOffset = Int32(exactly: end.int64Value), offset >= 0, endOffset >= offset,
                  let length = Int32(exactly: Int64(endOffset) - Int64(offset)) else { return nil }
            let entity: Api.MessageEntity
            switch kind.intValue {
            case 1: entity = .messageEntityMention(.init(offset: offset, length: length))
            case 2: entity = .messageEntityHashtag(.init(offset: offset, length: length))
            case 3: entity = .messageEntityBotCommand(.init(offset: offset, length: length))
            case 4: entity = .messageEntityUrl(.init(offset: offset, length: length))
            case 5: entity = .messageEntityEmail(.init(offset: offset, length: length))
            case 6: entity = .messageEntityBold(.init(offset: offset, length: length))
            case 7: entity = .messageEntityItalic(.init(offset: offset, length: length))
            case 8: entity = .messageEntityCode(.init(offset: offset, length: length))
            case 9: entity = .messageEntityPre(.init(offset: offset, length: length, language: fields["language"] as? String ?? ""))
            case 10:
                guard let url = fields["url"] as? String else { return nil }
                entity = .messageEntityTextUrl(.init(offset: offset, length: length, url: url))
            case 11:
                guard let peer = fields["peerId"] as? NSNumber else { return nil }
                entity = .messageEntityMentionName(.init(offset: offset, length: length, userId: peer.int64Value))
            case 12: entity = .messageEntityPhone(.init(offset: offset, length: length))
            case 13: entity = .messageEntityStrike(.init(offset: offset, length: length))
            case 14:
                guard let collapsed = fields["cl"] as? Bool else { return nil }
                entity = .messageEntityBlockquote(.init(flags: collapsed ? 1 : 0, offset: offset, length: length))
            case 15: entity = .messageEntityUnderline(.init(offset: offset, length: length))
            case 16: entity = .messageEntityBankCard(.init(offset: offset, length: length))
            case 17: entity = .messageEntitySpoiler(.init(offset: offset, length: length))
            case 18:
                guard let id = fields["f"] as? NSNumber else { return nil }
                entity = .messageEntityCustomEmoji(.init(offset: offset, length: length, documentId: id.int64Value))
            default: return nil
            }
            entity.serialize(buffer, true)
        }
        return buffer.makeData()
    }

    static func storedMediaIdentity(_ media: [Any]) -> Data? {
        guard !media.isEmpty else { return Data() }
        guard media.count == 1, let value = media.first else { return nil }
        if let image = HostValueReader.storedField("imageId", in: value),
           let id = HostValueReader.storedField("id", in: image).flatMap({ HostValueReader.rawNumber($0) }) {
            return Data("photo:\(id)".utf8)
        }
        if let file = HostValueReader.storedField("fileId", in: value),
           let id = HostValueReader.storedField("id", in: file).flatMap({ HostValueReader.rawNumber($0) }) {
            return Data("document:\(id)".utf8)
        }
        return nil
    }

    static func recordRenderedMessage(_ message: RenderedMessage, account: String) {
        guard let flags = HostValueReader.storedField("flags", in: message.value).flatMap({ HostValueReader.rawNumber($0) }) else { return }
        if flags & (1 << 2) == 0 {
            discardOwnEditHistory(id: message.id, peer: message.peer, account: account, namespace: message.namespace)
            return
        }
        guard isAntiEditEnabled else { return }
        guard let text = HostValueReader.storedField("text", in: message.value) as? String else { return }
        var editDate: Int32?
        var content = [String: Data]()
        if let attributes = HostValueReader.storedField("attributes", in: message.value) as? [Any] {
            var entities: [Any]? = []
            for attribute in attributes {
                let name = String(reflecting: type(of: attribute)).split(separator: ".").last
                if name == "EditedMessageAttribute" {
                    guard let date = HostValueReader.storedField("date", in: attribute).flatMap({ HostValueReader.rawNumber($0) }),
                          let parsedDate = Int32(exactly: date) else { return }
                    editDate = parsedDate
                }
                if name == "TextEntitiesMessageAttribute" {
                    entities = HostValueReader.storedField("entities", in: attribute) as? [Any]
                }
            }
            if let entities = entities { content["entities"] = storedEntities(entities) }
        }
        if let media = HostValueReader.storedField("media", in: message.value) as? [Any] {
            content["mediaIdentity"] = storedMediaIdentity(media)
        }
        let key = MessageKey(account: account, peer: message.peer, id: message.id, namespace: message.namespace)
        if editHistoryStore.record(text, key: key, editDate: editDate, content: content, localSnapshot: true) {
            notifyMessageEdited(key)
        }
    }

    @objc static func getHistoryAccountFromNode(_ node: Any) -> String? {
        return HostAccountReader.account(in: node, depth: 0)
    }
}
