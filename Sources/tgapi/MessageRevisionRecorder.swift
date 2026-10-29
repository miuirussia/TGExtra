import Foundation

extension TLParser {
    static let editHistoryStore = MessageHistoryStore()

    static var isAntiEditEnabled: Bool {
        return MessagePatches.Settings().keepEditHistory
    }

    static func recordText(_ text: String, forId id: Int32, peer: Int64,
                                   editDate: Int32?, allowUndatedEdit: Bool = false, content: [String: Data] = [:]) -> Bool {
        guard id != 0, peer != 0, let account = processingHistoryAccount else { return false }
        let key = MessageKey(account: account, peer: peer, id: id, namespace: processingNamespace)
        return editHistoryStore.record(text, key: key, editDate: editDate, allowUndatedEdit: allowUndatedEdit, content: content)
    }

    static func discardOwnEditHistory(id: Int32, peer: Int64, account: String?, namespace: Int32) {
        guard let account = account else { return }
        let key = MessageKey(account: account, peer: peer, id: id, namespace: namespace)
        let removed = editHistoryStore.discard(key)
        if removed { notifyMessageEdited(key) }
    }

    static func isOwnAuthor(_ author: Api.Peer?, account: String?) -> Bool {
        guard let account = account, case let .peerUser(data)? = author,
              let ownId = PeerInfoStore.ownUserId(for: account) else { return false }
        return data.userId == ownId.int64Value
    }

    static func revisionContent(entities: [Api.MessageEntity]?, media: Api.MessageMedia?, rich: Api.RichMessage?) -> [String: Data] {
        let entityBuffer = Buffer()
        for entity in entities ?? [] { entity.serialize(entityBuffer, true) }
        var content = ["entities": entityBuffer.makeData(), "mediaIdentity": Data(), "rich": Data()]
        if let media = media {
            content["media"] = serializeBoxed(media) as Data
            let identity: String
            switch media {
            case let .messageMediaPhoto(data):
                switch data.photo {
                case let .photo(data)?: identity = "photo:\(data.id)"
                case let .photoEmpty(data)?: identity = "photo:\(data.id)"
                default: identity = "photo"
                }
            case let .messageMediaDocument(data):
                switch data.document {
                case let .document(data)?: identity = "document:\(data.id)"
                case let .documentEmpty(data)?: identity = "document:\(data.id)"
                default: identity = "document"
                }
            case .messageMediaPoll, .messageMediaGeoLive, .messageMediaWebPage:
                identity = media.descriptionFields().0
            default:
                identity = ""
            }
            content["mediaIdentity"] = identity.isEmpty ? content["media"] : Data(identity.utf8)
        }
        if let rich = rich { content["rich"] = serializeBoxed(rich) as Data }
        return content
    }

    static func richText(_ value: Any, depth: Int = 0) -> String {
        guard depth < 48 else { return "" }
        let value = (value as? TLRecord).map(Api.view) ?? value
        if let message = value as? Api.RichMessage, case let .richMessage(data) = message {
            return data.blocks.map { richText($0, depth: depth + 1) }.joined(separator: "\n")
        }
        if let text = value as? Api.RichText {
            switch text {
            case let .textPlain(data): return data.text
            case let .textCustomEmoji(data): return data.alt
            case let .textMath(data): return data.source
            case let .textDiff(data): return richText(data.text, depth: depth + 1)
            default: break
            }
        }
        if let texts = value as? [Api.RichText] { return texts.map { richText($0, depth: depth + 1) }.joined() }
        if let record = Api.record(value), let descriptor = record.descriptor {
            let pieces = descriptor.fields.compactMap { field in
                record[field.name].map { richText(Api.exposedValue($0), depth: depth + 1) }
            }.filter { !$0.isEmpty }
            return pieces.joined(separator: record.typeName == "RichMessage" ? "\n" : "")
        }
        let mirror = Mirror(reflecting: value)
        let pieces = mirror.children.map { richText($0.value, depth: depth + 1) }.filter { !$0.isEmpty }
        return pieces.joined(separator: value is Api.RichMessage || mirror.displayStyle == .collection ? "\n" : "")
    }

    static func recordShortFormOriginal(id: Int32, text: String, peer: Int64, entities: [Api.MessageEntity]?, outgoing: Bool) {
        if outgoing {
            discardOwnEditHistory(id: id, peer: peer, account: processingHistoryAccount, namespace: processingNamespace)
            return
        }
        guard packetSettings.keepEditHistory else { return }
        guard id != 0 else { return }
        diag("anti-edit RECORD id=\(id) peer=\(peer) \(text.count) chars")
        _ = recordText(text, forId: id, peer: peer, editDate: nil, content: revisionContent(entities: entities, media: nil, rich: nil))
    }

    static func trackMessageVersions(_ apiMsg: Api.Message, allowUndatedEdit: Bool = false) {
        guard case let .message(data) = apiMsg else { return }
        guard data.id != 0 else { return }

        let peer = peerKey(data.peerId)
        if data.flags & (1 << 1) != 0 || isOwnAuthor(data.fromId, account: processingHistoryAccount) {
            discardOwnEditHistory(id: data.id, peer: peer, account: processingHistoryAccount, namespace: processingNamespace)
            return
        }
        guard packetSettings.keepEditHistory else { return }
        let text = data.richMessage.map { richText($0) }.flatMap { $0.isEmpty ? nil : $0 } ?? data.message
        let content = revisionContent(entities: data.entities, media: data.media, rich: data.richMessage)
        guard recordText(text, forId: data.id, peer: peer, editDate: data.editDate,
                         allowUndatedEdit: allowUndatedEdit, content: content),
              let account = processingHistoryAccount else { return }
        diag("anti-edit VERSION id=\(data.id) peer=\(peer) account=\(account)")

        notifyMessageEdited(MessageKey(account: account, peer: peer, id: data.id, namespace: processingNamespace))
    }

    static func trackVersions(in msgs: [Api.Message]) {
        msgs.forEach { trackMessageVersions($0) }
    }

    static func notifyMessageEdited(_ key: MessageKey) {
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: NSNotification.Name("TGExtraMessageEditedRealtime"),
                object: nil, userInfo: ["ids": [NSNumber(value: key.id)], "account": key.account,
                                       "peer": NSNumber(value: key.peer), "namespace": NSNumber(value: key.namespace)])
        }
    }
}
