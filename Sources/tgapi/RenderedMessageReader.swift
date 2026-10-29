import Foundation

// Reads stored host UI values without invoking computed Swift properties.
enum RenderedMessageReader {
    struct RenderedMessage {
        let value: Any
        let id: Int32
        let peer: Int64
        let namespace: Int32
    }

    static func renderedMessage(_ value: Any) -> RenderedMessage? {
        let message = HostValueReader.unwrapOptional(value)
        guard let messageId = HostValueReader.storedField("id", in: message),
              let idValue = HostValueReader.storedField("id", in: messageId), let rawId = HostValueReader.rawNumber(idValue),
              let id = Int32(exactly: rawId), id != 0,
              let namespaceValue = HostValueReader.storedField("namespace", in: messageId),
              let rawNamespace = HostValueReader.rawNumber(namespaceValue), let namespace = Int32(exactly: rawNamespace),
              let peerId = HostValueReader.storedField("peerId", in: messageId),
              let peer = peerKey(fromPeerId: peerId), peer != 0 else { return nil }
        return RenderedMessage(value: message, id: id, peer: peer, namespace: namespace)
    }

    static func tupleMessage(_ value: Any) -> Any? {
        let value = HostValueReader.unwrapOptional(value)
        if Mirror(reflecting: value).displayStyle == .tuple {
            return HostValueReader.storedField("message", in: value) ?? HostValueReader.storedField(".0", in: value)
        }
        return value
    }

    /// ChatMessageItemContent.message(message:read:selection:attributes:location:)
    /// and .group(messages: [(Message, Bool, Selection, Attributes, Location?)]).
    static func renderedMessages(from item: Any) -> [RenderedMessage] {
        guard let content = HostValueReader.storedField("content", in: item) else { return [] }
        let mirror = Mirror(reflecting: HostValueReader.unwrapOptional(content))
        guard mirror.displayStyle == .enum, let payload = mirror.children.first else { return [] }
        switch payload.label {
        case "message":
            guard let value = tupleMessage(payload.value), let message = renderedMessage(value) else { return [] }
            return [message]
        case "group":
            let group = HostValueReader.storedField("messages", in: payload.value) ?? payload.value
            let collection = Mirror(reflecting: HostValueReader.unwrapOptional(group))
            guard collection.displayStyle == .collection else { return [] }
            // Do not choose a later member when the leading message is unknown.
            // That would bind the pencil to a different message from firstMessage.
            var result = [RenderedMessage]()
            for row in collection.children {
                guard let value = tupleMessage(row.value), let message = renderedMessage(value) else { return [] }
                result.append(message)
            }
            return result
        default: return []
        }
    }

    static func renderedMessagesFromNode(_ node: Any) -> [RenderedMessage] {
        guard let item = HostValueReader.storedField("item", in: node) else { return [] }
        return renderedMessages(from: item)
    }

    static func peerKey(fromPeerId value: Any) -> Int64? {
        guard let nsValue = HostValueReader.storedField("namespace", in: value), let namespace = HostValueReader.rawNumber(nsValue),
              let idValue = HostValueReader.storedField("id", in: value), let id = HostValueReader.rawNumber(idValue),
              id > 0, id <= Int64.max - 1_000_000_000_000 else { return nil }
        switch namespace {
        case 0: return id
        case 1: return -id
        case 2: return -(1_000_000_000_000 + id)
        default: return nil
        }
    }

}
