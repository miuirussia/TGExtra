import Foundation

@objc(TGExtraProfileBridge)
final class ProfileBridge: NSObject {
    @objc static var sharedContext: Any?

    @objc static func debugPeerCandidates(_ node: Any) -> NSString {
        var out = [String]()

        var currentMirror: Mirror? = Mirror(reflecting: node)
        var depth = 0
        while let mirror = currentMirror, depth < 3 {
            let labels = mirror.children.compactMap { $0.label }
            if !labels.isEmpty {
                out.append("L\(depth):[\(labels.joined(separator: ","))]")
            }
            for child in mirror.children {
                guard let label = child.label,
                      label.lowercased().contains("peer") else { continue }
                out.append("\(label)=\(String(describing: child.value).prefix(140))")
            }
            currentMirror = mirror.superclassMirror
            depth += 1
        }

        if let obj = node as? NSObject {
            for key in ["peer", "peerId"] where obj.responds(to: NSSelectorFromString(key)) {
                let value = obj.value(forKey: key)
                out.append("kvc.\(key)=\(String(describing: value).prefix(140))")
            }
        }

        return NSString(string: out.isEmpty ? "(no peer-ish members)" : out.joined(separator: " | "))
    }

    @objc static func getPeerIdFromNode(_ node: Any) -> NSNumber? {
        if sharedContext == nil, let obj = node as? NSObject {
            if obj.responds(to: NSSelectorFromString("context")), let ctx = obj.value(forKey: "context") {
                sharedContext = ctx
            }
        }

        if let obj = node as? NSObject {
            for key in ["peer", "peerId", "_peer", "_peerId", "id"] {
                if obj.responds(to: NSSelectorFromString(key)), let val = obj.value(forKey: key) {
                    if let pid = extractId(fromPeer: val) { return pid }
                    if let pid = extractId(fromPeerId: val) { return pid }
                }
            }
        }

        var currentMirror: Mirror? = Mirror(reflecting: node)
        while let mirror = currentMirror {
            for child in mirror.children {
                let label = child.label ?? ""
                if ["peer", "_peer", "peerId", "_peerId", "id"].contains(label) {
                    if let pid = extractId(fromPeer: child.value) { return pid }
                    if let pid = extractId(fromPeerId: child.value) { return pid }
                } else if label == "state" {
                    let stateMirror = Mirror(reflecting: child.value)
                    for stateChild in stateMirror.children {
                        if stateChild.label == "peer" || stateChild.label == "peerId" {
                            if let pid = extractId(fromPeer: stateChild.value) { return pid }
                        }
                    }
                }
            }
            currentMirror = mirror.superclassMirror
        }

        return nil
    }

    private static func extractId(fromPeer peer: Any) -> NSNumber? {
        if let pid = findIdByReflection(peer, depth: 0) { return pid }

        if let obj = peer as? NSObject {
            if obj.responds(to: NSSelectorFromString("id")), let pid = obj.value(forKey: "id") {
                return extractId(fromPeerId: pid)
            }
        }

        return nil
    }

    private static func findIdByReflection(_ value: Any, depth: Int) -> NSNumber? {
        guard depth < 6 else { return nil }

        let mirror = Mirror(reflecting: value)
        if HostValueReader.storedField("namespace", in: value) != nil {
            return extractId(fromPeerId: value)
        }

        for child in mirror.children where child.label == "id" {
            if let pid = extractId(fromPeerId: child.value) { return pid }
        }

        switch mirror.displayStyle {
        case .optional, .enum:
            for child in mirror.children {
                if let pid = findIdByReflection(child.value, depth: depth + 1) { return pid }
            }
        default:
            break
        }

        return nil
    }

    private static func extractId(fromPeerId value: Any) -> NSNumber? {
        let value = HostValueReader.unwrapOptional(value)
        if HostValueReader.storedField("namespace", in: value) != nil {
            return RenderedMessageReader.peerKey(fromPeerId: value).map(NSNumber.init(value:))
        }
        guard let id = HostValueReader.rawNumber(value), id > 0 else { return nil }
        return NSNumber(value: id)
    }

    @objc static func getPeerDisplayInfoFromNode(_ node: Any) -> [String: String] {
        var result = [String: String]()

        guard let fields = findPeerFieldsByReflection(node, depth: 0) else { return result }

        if let username = fields["username"], !username.isEmpty {
            result["username"] = username
        }

        let name = ["firstName", "lastName"]
            .compactMap { fields[$0] }
            .filter { !$0.isEmpty }
            .joined(separator: " ")

        if !name.isEmpty {
            result["name"] = name
        } else if let title = fields["title"], !title.isEmpty {
            result["name"] = title
        }

        return result
    }

    private static func findPeerFieldsByReflection(_ value: Any, depth: Int) -> [String: String]? {
        guard depth < 6 else { return nil }

        let wanted: Set<String> = ["firstName", "lastName", "username", "title"]
        let mirror = Mirror(reflecting: value)

        var found = [String: String]()
        var hasId = false

        for child in mirror.children {
            guard let label = child.label else { continue }
            if label == "id" { hasId = true }
            guard wanted.contains(label) else { continue }
            if let text = unwrapString(child.value) {
                found[label] = text
            }
        }

        if hasId && !found.isEmpty {
            return found
        }

        switch mirror.displayStyle {
        case .optional, .enum:
            for child in mirror.children {
                if let nested = findPeerFieldsByReflection(child.value, depth: depth + 1) {
                    return nested
                }
            }
        default:
            for child in mirror.children {
                guard let label = child.label,
                      label == "peer" || label == "_peer" else { continue }
                if let nested = findPeerFieldsByReflection(child.value, depth: depth + 1) {
                    return nested
                }
            }
        }

        return nil
    }

    private static func unwrapString(_ value: Any) -> String? {
        if let text = value as? String { return text.isEmpty ? nil : text }
        let mirror = Mirror(reflecting: value)
        guard mirror.displayStyle == .optional, let child = mirror.children.first else { return nil }
        return unwrapString(child.value)
    }

    @objc static func getOwnUserIdFromNode(_ node: Any) -> NSNumber? {
        let account = HostAccountReader.account(in: node)
        if let id = findNodeAccountPeerId(node, depth: 0) {
            if let account = account { PeerInfoStore.rememberOwnUserId(id.int64Value, account: account) }
            return id
        }
        guard let account = account else { return nil }
        return PeerInfoStore.ownUserId(for: account)
    }

    private static func findNodeAccountPeerId(_ wrapped: Any, depth: Int) -> NSNumber? {
        guard depth <= 6 else { return nil }
        var mirror: Mirror? = Mirror(reflecting: HostValueReader.unwrapOptional(wrapped))
        while let current = mirror {
            for child in current.children {
                if child.label == "account", let id = findOwnPeerId(child.value, depth: 0) { return id }
                if ["item", "context"].contains(child.label ?? ""),
                   let id = findNodeAccountPeerId(child.value, depth: depth + 1) { return id }
            }
            mirror = current.superclassMirror
        }
        return nil
    }

    @objc static func getCurrentUserId() -> NSNumber? {
        if let context = sharedContext, let id = findOwnPeerId(context, depth: 0) {
            UserDefaults.standard.set(id.int64Value, forKey: "TGExtraLastKnownUserId")
            return id
        }
        let savedId = UserDefaults.standard.integer(forKey: "TGExtraLastKnownUserId")
        if savedId != 0 { return NSNumber(value: Int64(savedId)) }
        return nil
    }

    private static func findOwnPeerId(_ value: Any, depth: Int) -> NSNumber? {
        guard depth < 5 else { return nil }
        let mirror = Mirror(reflecting: value)

        for child in mirror.children where child.label == "peerId" {
            if let id = extractId(fromPeerId: child.value) { return id }
        }

        for child in mirror.children {
            let followable = (child.label == "account") || (child.label == "context")
                || (child.label == "some") || (child.label == nil)
            guard followable || mirror.displayStyle == .optional else { continue }
            if let id = findOwnPeerId(child.value, depth: depth + 1) { return id }
        }
        return nil
    }
}
