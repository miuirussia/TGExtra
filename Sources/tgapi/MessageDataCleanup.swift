import Foundation
import tgapiC

// Retain deletion targets until their account's Postbox commits the removal.
enum MessageDataCleanup {
    static let storageKey = "TGExtraPendingMessageCleanup"
    // Unlike an explicit cleanup, expired messages wait until timer protection is off.
    private static let expiryMarker = 1 << 8
    private static let queue = DispatchQueue(label: "TGExtra.MessageCleanup")
    private static let postboxes = NSMapTable<NSString, AnyObject>(keyOptions: .strongMemory, valueOptions: .weakMemory)
    private static var ownPeers = [String: Int64]()
    private static var running = Set<String>()
    private static var retrying = Set<String>()
#if TGEXTRA_TESTING
    private static let expiryRetryInterval: TimeInterval = 0.05
#else
    private static let expiryRetryInterval: TimeInterval = 30
#endif

    // Postbox PeerId and MessageId layout, also used by SecretChatDeletion.
    struct LocalMessageId {
        let peerNamespace: UInt32
        let peer: Int64
        let namespace: Int32
        let id: Int32
    }

    static func peer(_ key: Int64, messageNamespace: Int32) -> (UInt32, Int64) {
        if (messageNamespace == 1 || messageNamespace == 2) && key <= -1_000_000_000_000 {
            return (3, -key - 2_000_000_000_000)
        }
        if key <= -1_000_000_000_000 { return (2, -key - 1_000_000_000_000) }
        if key < 0 { return (1, -key) }
        return (0, key)
    }

    static func register(from wrapped: Any, depth: Int = 0) {
        guard depth <= 6 else { return }
        let value = HostValueReader.unwrapOptional(wrapped)
        if let wrappedPostbox = HostValueReader.storedField("postbox", in: value) {
            let postbox = HostValueReader.unwrapOptional(wrappedPostbox)
            if Mirror(reflecting: postbox).displayStyle == .class,
               String(reflecting: type(of: postbox)) == "Postbox.Postbox",
               let account = HostAccountReader.account(in: value) ?? HostAccountReader.account(in: postbox) {
                let ownPeer = HostValueReader.storedField("peerId", in: value)
                    .flatMap { HostValueReader.storedField("id", in: $0) }
                    .flatMap { HostValueReader.rawNumber($0) }
                queue.async {
                    postboxes.setObject(postbox as AnyObject, forKey: account as NSString)
                    if let ownPeer = ownPeer, ownPeer > 0 { ownPeers[account] = ownPeer }
                    drain(account)
                }
                return
            }
        }
        for name in ["item", "context", "account"] {
            if let child = HostValueReader.storedField(name, in: value) { register(from: child, depth: depth + 1) }
        }
    }

    static func enqueue(_ markers: [MessageKey: Int]) {
        queue.sync {
            var pending = UserDefaults.standard.dictionary(forKey: storageKey) as? [String: Int] ?? [:]
            // Clear Message Database also removes messages retained by expired timers.
            for (name, bits) in pending where bits & expiryMarker != 0 {
                pending[name] = (bits & ~expiryMarker) | TLParser.deletedMarker
            }
            for (key, bits) in markers where (key.id == 0 && bits > 0) || bits & TLParser.deletedMarker != 0 {
                pending[key.storageKey] = key.id == 0 ? max(pending[key.storageKey] ?? 0, bits) :
                    (pending[key.storageKey, default: 0] & ~expiryMarker) | bits
            }
            if !pending.isEmpty { UserDefaults.standard.set(pending, forKey: storageKey) }
        }
    }

    static func deferExpiry(_ key: MessageKey) {
        queue.sync {
            var pending = UserDefaults.standard.dictionary(forKey: storageKey) as? [String: Int] ?? [:]
            // An explicit cleanup already queued for this ID takes precedence.
            if pending[key.storageKey] == nil { pending[key.storageKey] = expiryMarker }
            UserDefaults.standard.set(pending, forKey: storageKey)
        }
        queue.async { drain(key.account) }
    }

    static func start() {
        queue.async {
            let pending = UserDefaults.standard.dictionary(forKey: storageKey) ?? [:]
            let accounts = Set(pending.keys.compactMap { MessageKey(storageKey: $0)?.account })
            for account in accounts { drain(account) }
        }
    }

    private static func drain(_ account: String) {
        guard !running.contains(account) else { return }
        let pending = UserDefaults.standard.dictionary(forKey: storageKey) as? [String: Int] ?? [:]
        let batch = pending.filter { MessageKey(storageKey: $0.key)?.account == account }
        if batch.values.contains(where: { $0 & expiryMarker != 0 }), retrying.insert(account).inserted {
            queue.asyncAfter(deadline: .now() + expiryRetryInterval) {
                retrying.remove(account)
                drain(account)
            }
        }
        guard TGExtraMessageCleanupAvailable(),
              let postbox = postboxes.object(forKey: account as NSString) else { return }
        let quickReplyPeer = ownPeers[account]
        // Cloud global IDs have no peer; other namespaces require a peer.
        let targets = batch.compactMap { name, bits -> (MessageKey, Int)? in
            if bits & expiryMarker != 0 && SecretChatPolicy.shouldBlock(event: 2, peerNamespace: 3) { return nil }
            guard let key = MessageKey(storageKey: name),
                  key.peer != 0 || key.namespace == 0 || (key.namespace == 5 && quickReplyPeer != nil) else { return nil }
            return (key, bits)
        }
        guard !targets.isEmpty else { return }
        running.insert(account)
        var executed = [(MessageKey, Int)]()
        let body: (UnsafeMutableRawPointer) -> Void = { pointer in
            let targets = targets.filter { _, bits in
                bits & expiryMarker == 0 || !SecretChatPolicy.shouldBlock(event: 2, peerNamespace: 3)
            }
            executed = targets
            let globalIds = targets.compactMap { key, _ in key.peer == 0 && key.namespace == 0 && key.id != 0 ? key.id : nil }
            if !globalIds.isEmpty {
                withExtendedLifetime(globalIds) {
                    TGExtraDeleteLocalMessages(pointer, unsafeBitCast(globalIds, to: UnsafeMutableRawPointer.self), true)
                }
            }
            let localIds = targets.compactMap { key, _ -> LocalMessageId? in
                guard key.id != 0, let messagePeer = key.peer == 0 ? (key.namespace == 5 ? quickReplyPeer : nil) : key.peer else { return nil }
                let (namespace, id) = peer(messagePeer, messageNamespace: key.namespace)
                return LocalMessageId(peerNamespace: namespace, peer: id, namespace: key.namespace, id: key.id)
            }
            if !localIds.isEmpty {
                withExtendedLifetime(localIds) {
                    TGExtraDeleteLocalMessages(pointer, unsafeBitCast(localIds, to: UnsafeMutableRawPointer.self), false)
                }
            }
            for (key, maxId) in targets where key.id == 0 && key.peer != 0 {
                guard let maxId = Int32(exactly: maxId), maxId > 0 else { continue }
                let (namespace, id) = peer(key.peer, messageNamespace: key.namespace)
                TGExtraDeleteLocalMessageRange(pointer, namespace, id, key.namespace, maxId)
            }
        }
        let completed: () -> Void = {
            queue.async {
                var remaining = UserDefaults.standard.dictionary(forKey: storageKey) as? [String: Int] ?? [:]
                for (key, bits) in executed where remaining[key.storageKey] == bits { remaining.removeValue(forKey: key.storageKey) }
                if remaining.isEmpty { UserDefaults.standard.removeObject(forKey: storageKey) }
                else { UserDefaults.standard.set(remaining, forKey: storageKey) }
                running.remove(account)
                drain(account)
            }
        }
        let callbacks = MessageCleanupCallbacks(body: body, completed: completed)
        withExtendedLifetime((postbox, callbacks)) {
            TGExtraRunMessageCleanup(Unmanaged.passUnretained(postbox).toOpaque(), Unmanaged.passUnretained(callbacks).toOpaque(),
                unsafeBitCast(Void.self, to: UnsafeRawPointer.self))
        }
    }
}

private final class MessageCleanupCallbacks {
    let body: (UnsafeMutableRawPointer) -> Void
    let completed: () -> Void
    init(body: @escaping (UnsafeMutableRawPointer) -> Void, completed: @escaping () -> Void) {
        self.body = body
        self.completed = completed
    }
}

@_cdecl("TGExtraMessageCleanupBody")
func messageCleanupBody(_ context: UnsafeMutableRawPointer, _ transaction: UnsafeMutableRawPointer) {
    Unmanaged<MessageCleanupCallbacks>.fromOpaque(context).takeUnretainedValue().body(transaction)
}

@_cdecl("TGExtraMessageCleanupCompleted")
func messageCleanupCompleted(_ context: UnsafeMutableRawPointer) {
    Unmanaged<MessageCleanupCallbacks>.fromOpaque(context).takeUnretainedValue().completed()
}

extension TLParser {
    @objc static func registerMessageCleanupContext(_ context: Any) {
        MessageDataCleanup.register(from: context)
    }
}
