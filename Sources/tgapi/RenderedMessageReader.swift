import Foundation

// Reads stored host UI values without invoking computed Swift properties.
enum RenderedMessageReader {
    static func storedField(_ name: String, in value: Any) -> Any? {
        var mirror: Mirror? = Mirror(reflecting: unwrapOptional(value))
        while let current = mirror {
            if let field = current.children.first(where: { $0.label == name }) { return field.value }
            mirror = current.superclassMirror
        }
        return nil
    }

    struct RenderedMessage {
        let value: Any
        let id: Int32
        let peer: Int64
        let namespace: Int32
    }

    static func renderedMessage(_ value: Any) -> RenderedMessage? {
        let message = unwrapOptional(value)
        guard let messageId = storedField("id", in: message),
              let idValue = storedField("id", in: messageId), let rawId = rawNumber(idValue),
              let id = Int32(exactly: rawId), id != 0,
              let namespaceValue = storedField("namespace", in: messageId),
              let rawNamespace = rawNumber(namespaceValue), let namespace = Int32(exactly: rawNamespace),
              let peerId = storedField("peerId", in: messageId),
              let peer = peerKey(fromPeerId: peerId), peer != 0 else { return nil }
        return RenderedMessage(value: message, id: id, peer: peer, namespace: namespace)
    }

    static func tupleMessage(_ value: Any) -> Any? {
        let value = unwrapOptional(value)
        if Mirror(reflecting: value).displayStyle == .tuple {
            return storedField("message", in: value) ?? storedField(".0", in: value)
        }
        return value
    }

    /// ChatMessageItemContent.message(message:read:selection:attributes:location:)
    /// and .group(messages: [(Message, Bool, Selection, Attributes, Location?)]).
    static func renderedMessages(from item: Any) -> [RenderedMessage] {
        guard let content = storedField("content", in: item) else { return [] }
        let mirror = Mirror(reflecting: unwrapOptional(content))
        guard mirror.displayStyle == .enum, let payload = mirror.children.first else { return [] }
        switch payload.label {
        case "message":
            guard let value = tupleMessage(payload.value), let message = renderedMessage(value) else { return [] }
            return [message]
        case "group":
            let group = storedField("messages", in: payload.value) ?? payload.value
            let collection = Mirror(reflecting: unwrapOptional(group))
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
        guard let item = storedField("item", in: node) else { return [] }
        return renderedMessages(from: item)
    }

    static func rawNumber(_ value: Any) -> Int64? {
        let value = unwrapOptional(value)
        if let v = value as? Int64 { return v }
        if let v = value as? Int32 { return Int64(v) }
        if let v = value as? UInt32 { return Int64(v) }
        guard let raw = storedField("rawValue", in: value) else { return nil }
        if let v = raw as? Int64 { return v }
        if let v = raw as? Int32 { return Int64(v) }
        if let v = raw as? UInt32 { return Int64(v) }
        return nil
    }

    static func unwrapOptional(_ value: Any) -> Any {
        var current = value
        while true {
            let mirror = Mirror(reflecting: current)
            guard mirror.displayStyle == .optional,
                  let inner = mirror.children.first?.value else { return current }
            current = inner
        }
    }

    static func peerKey(fromPeerId value: Any) -> Int64? {
        guard let nsValue = storedField("namespace", in: value), let namespace = rawNumber(nsValue),
              let idValue = storedField("id", in: value), let id = rawNumber(idValue),
              id > 0, id <= Int64.max - 1_000_000_000_000 else { return nil }
        switch namespace {
        case 0: return id
        case 1: return -id
        case 2: return -(1_000_000_000_000 + id)
        default: return nil
        }
    }

}
