import Foundation

// Adapts host profile nodes for the Ghost Exceptions UI.
@objc(TGExtraProfileBridge)
final class ProfileBridge: NSObject {
    @objc static var sharedContext: Any?

    /// Diagnostic only — reports what a node actually exposes that might carry a
    /// peer, so a failing profile lookup can be read off a device log instead of
    /// guessed at. No feature depends on this.
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
        // Try to sniff sharedContext from any node that might have it
        if sharedContext == nil, let obj = node as? NSObject {
            if obj.responds(to: NSSelectorFromString("context")), let ctx = obj.value(forKey: "context") {
                sharedContext = ctx
            }
        }

        // Try KVC first
        if let obj = node as? NSObject {
            for key in ["peer", "peerId", "_peer", "_peerId", "id"] {
                if obj.responds(to: NSSelectorFromString(key)), let val = obj.value(forKey: key) {
                    if let pid = extractId(fromPeer: val) { return pid }
                    if let pid = extractId(fromPeerId: val) { return pid }
                }
            }
        }

        // Try Mirror
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

        // NUCLEAR FALLBACK: Regex on full object description
        let fullDesc = String(describing: node)
        if let pid = extractId(fromPeer: fullDesc) { return pid }

        return nil
    }

    private static func extractId(fromPeer peer: Any) -> NSNumber? {
        // Reflection first: it addresses the peer's actual `id`, whereas the
        // description regex below can just as easily latch onto some unrelated
        // number that happens to sit after an "id:" in the dumped text.
        if let pid = findIdByReflection(peer, depth: 0) { return pid }

        if let obj = peer as? NSObject {
            if obj.responds(to: NSSelectorFromString("id")), let pid = obj.value(forKey: "id") {
                return extractId(fromPeerId: pid)
            }
        }

        let desc = String(describing: peer)
        if let range = desc.range(of: "(id|userId|channelId):\\s*(-?\\d+)", options: .regularExpression) {
            let match = desc[range]
            if let idRange = match.range(of: "-?\\d+", options: .regularExpression) {
                if let idVal = Int64(match[idRange]) { return NSNumber(value: idVal) }
            }
        }

        return nil
    }

    /// Walks a peer value down to its `id`, unwrapping containers on the way.
    ///
    /// PeerInfoHeaderNode holds `peer: EnginePeer?` — an Optional around an enum
    /// around the concrete TelegramUser. Reflecting that yields a child labelled
    /// after the enum case ("user"), never "id", so a single-level search comes
    /// back empty and the caller reads the peer as absent. Unwrap Optionals and
    /// enum payloads until the value carrying `id: PeerId` surfaces.
    private static func findIdByReflection(_ value: Any, depth: Int) -> NSNumber? {
        guard depth < 6 else { return nil }

        let mirror = Mirror(reflecting: value)

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

    private static func extractId(fromPeerId pid: Any) -> NSNumber? {
        if let idVal = pid as? Int64 { return NSNumber(value: idVal) }
        if let idVal = pid as? Int32 { return NSNumber(value: Int64(idVal)) }

        // Postbox's PeerId reflects as `namespace` + `id`, where `id` is an Id
        // struct wrapping `rawValue: Int64`. Walk to that Int64 first; the
        // description forms below are only fallbacks.
        let pidMirror = Mirror(reflecting: pid)
        for pidChild in pidMirror.children {
            guard pidChild.label == "id" || pidChild.label == "_value" || pidChild.label == "value" else { continue }
            if let idVal = pidChild.value as? Int64 { return NSNumber(value: idVal) }
            if let idVal = pidChild.value as? Int32 { return NSNumber(value: Int64(idVal)) }
            for inner in Mirror(reflecting: pidChild.value).children where inner.label == "rawValue" {
                if let idVal = inner.value as? Int64 { return NSNumber(value: idVal) }
                if let idVal = inner.value as? Int32 { return NSNumber(value: Int64(idVal)) }
            }
        }

        let desc = String(describing: pid)

        // PeerId.description is "<namespace>:<id>" (Postbox/Sources/Peer.swift).
        // Grabbing the first number would return the namespace — and CloudUser's
        // namespace is 0, so every user peer would read as "no peer at all".
        if let idPart = firstCapture(in: desc, pattern: "^\\s*(?:PeerId\\()?\\d+:(-?\\d+)\\)?\\s*$"),
           let idVal = Int64(idPart) {
            return NSNumber(value: idVal)
        }

        if let range = desc.range(of: "-?\\d+", options: .regularExpression) {
            if let idVal = Int64(desc[range]) {
                return NSNumber(value: idVal)
            }
        }

        return nil
    }

    /// Best-effort name and username for a profile header, used when adding a
    /// Ghost Exception so the list has something readable to show.
    ///
    /// Reads stored Swift fields because PeerInfoScreen's internals are not
    /// exposed to Objective-C. Called on a tap, never from layout.
    @objc static func getPeerDisplayInfoFromNode(_ node: Any) -> [String: String] {
        var result = [String: String]()

        // TelegramUser is a plain Swift class, so String(describing:) prints
        // nothing but its type name — scraping text for "firstName:" finds
        // nothing at all. Reflect over the real stored properties instead.
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

    /// Finds the concrete peer under a node and returns its name-ish fields.
    ///
    /// Mirrors the unwrapping in findIdByReflection: the peer sits behind an
    /// Optional and an enum case before its stored properties are reachable.
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
            // Values are Optional<String>; unwrap before stringifying, or every
            // one of them reads back as "Optional(\"…\")".
            if let text = unwrapString(child.value) {
                found[label] = text
            }
        }

        // `id` alongside a name field means this really is the peer, not some
        // outer container that happens to expose a "title".
        if hasId && !found.isEmpty {
            return found
        }

        // Descend only along the peer path. Following every member instead would
        // walk the whole display-node tree — thousands of objects deep.
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

    private static func firstCapture(in text: String, pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        guard let match = regex.firstMatch(in: text, options: [], range: range),
              match.numberOfRanges > 1,
              let captured = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[captured])
    }

    private static func unwrapString(_ value: Any) -> String? {
        if let text = value as? String { return text.isEmpty ? nil : text }
        let mirror = Mirror(reflecting: value)
        guard mirror.displayStyle == .optional, let child = mirror.children.first else { return nil }
        return unwrapString(child.value)
    }

    /// Resolve the account belonging to this screen, even when another account
    /// last opened a chat or delivered a background response.
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
            // Cached the moment it resolves, so the answer survives a launch
            // where the context has not been handed over yet.
            UserDefaults.standard.set(id.int64Value, forKey: "TGExtraLastKnownUserId")
            return id
        }
        let savedId = UserDefaults.standard.integer(forKey: "TGExtraLastKnownUserId")
        if savedId != 0 { return NSNumber(value: Int64(savedId)) }
        return nil
    }

    /// Finds account.peerId inside the shared context.
    ///
    /// The previous version stepped exactly two levels, context.account then
    /// .peerId, and gave up the moment either was wrapped — in an Optional, or
    /// behind one more holder object. Returning nil there meant the tweak could
    /// not tell your own profile from anyone else's, which is how the Ghost
    /// Exception eye ended up offered on yourself.
    private static func findOwnPeerId(_ value: Any, depth: Int) -> NSNumber? {
        guard depth < 5 else { return nil }
        let mirror = Mirror(reflecting: value)

        for child in mirror.children where child.label == "peerId" {
            if let id = extractId(fromPeerId: child.value) { return id }
        }

        for child in mirror.children {
            // Only follow the account chain, plus the wrappers that can sit in
            // the middle of it. Descending everywhere would happily return some
            // unrelated peerId from elsewhere in the context.
            let followable = (child.label == "account") || (child.label == "context")
                || (child.label == "some") || (child.label == nil)
            guard followable || mirror.displayStyle == .optional else { continue }
            if let id = findOwnPeerId(child.value, depth: depth + 1) { return id }
        }
        return nil
    }
}
