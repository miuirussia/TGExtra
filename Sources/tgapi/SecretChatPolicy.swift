import Foundation

@objc(TGExtraSecretChatPolicy)
final class SecretChatPolicy: NSObject {
    private static let lock = NSLock()
    private static var observedEvents = Set<Int32>()

    static func recordEvent(_ event: Int32) {
        lock.lock()
        observedEvents.insert(event)
        lock.unlock()
    }

    static var compatibilityStatus: String {
        let names: [Int32: String] = [0: "screenshots", 1: "remote deletion", 2: "expiry", 3: "media consumption"]
        lock.lock()
        let observed = observedEvents.sorted().compactMap { names[$0] }
        lock.unlock()
        if !observed.isEmpty { return "observed: " + observed.joined(separator: ", ") }
        let path = Bundle.main.bundlePath + "/TGExtraSecretChats.plist"
        if let config = NSDictionary(contentsOfFile: path), config["ABI"] as? Int == 1 {
            return "ipatch metadata present; awaiting runtime calls"
        }
        return "requires a compatible Secret Chat Protection ipatch profile"
    }

    // Events and the PeerId namespace ABI are checked by the secret-chat profiles.
    static func shouldBlock(event: Int32, peerNamespace: Int32) -> Bool {
        let defaults = UserDefaults.standard
        switch event {
        case 0: return defaults.bool(forKey: "TGExtraDisableScreenshotNotification")
        case 1: return defaults.bool(forKey: "TGExtraAntiRevoke")
        case 2:
            return peerNamespace == 3 && (defaults.bool(forKey: "TGExtraAntiSelfDestruct") ||
                defaults.bool(forKey: "TGExtraAntiAutoDelete"))
        case 3:
            return peerNamespace == 3 && defaults.bool(forKey: "TGExtraAntiSelfDestruct")
        default: return false
        }
    }

    @objc(isSecretGalleryItem:)
    static func isSecretGalleryItem(_ node: AnyObject) -> Bool {
        if let message = HostValueReader.storedField("message", in: node), isSecretMessage(message) { return true }
        if let item = HostValueReader.storedField("item", in: node),
           let info = HostValueReader.storedField("contentInfo", in: item) {
            let mirror = Mirror(reflecting: HostValueReader.unwrapOptional(info))
            if mirror.displayStyle == .enum, let payload = mirror.children.first, payload.label == "message",
               let message = HostValueReader.storedField(".0", in: payload.value), isSecretMessage(message) { return true }
        }
        return false
    }

    static func isSecretMessage(_ message: Any) -> Bool {
        guard let id = HostValueReader.storedField("id", in: message),
              let peer = HostValueReader.storedField("peerId", in: id),
              let namespace = HostValueReader.storedField("namespace", in: peer) else { return false }
        return HostValueReader.rawNumber(namespace) == 3
    }
}

@_cdecl("TGExtraSecretChatShouldBlock")
public func secretChatShouldBlock(_ event: Int32, _ peerNamespace: Int32) -> Int32 {
    SecretChatPolicy.recordEvent(event)
    return SecretChatPolicy.shouldBlock(event: event, peerNamespace: peerNamespace) ? 1 : 0
}
