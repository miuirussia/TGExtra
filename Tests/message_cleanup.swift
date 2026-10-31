import Foundation
import Postbox
import tgapiC

@objc(TLParser) class TLParser: NSObject {
    static let deletedMarker = 1
    static let processingLock = NSLock()
    static var markerBatchDepth = 0
    static var markers = [MessageKey: Int]()
    static func recordMarker(_ bits: Int, id: Int32, peer: Int64, account: String?, namespace: Int32) {
        markers[MessageKey(account: account!, peer: peer, id: id, namespace: namespace)] = bits
    }
    static func flushMarkers() {}
}
final class Context {
    let account: Account
    init(_ postbox: Postbox) { account = Account(postbox) }
}
final class Account {
    let basePath: String
    let postbox: Postbox
    let peerId = PeerId(namespace: 0, id: 42)
    init(_ postbox: Postbox) { self.postbox = postbox; basePath = postbox.accountPath }
}

func require(_ value: @autoclosure () -> Bool, _ label: String) {
    precondition(value(), label)
}
func waitFor(_ label: String, _ condition: () -> Bool) {
    let deadline = Date(timeIntervalSinceNow: 3)
    while !condition() && Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
    require(condition(), label)
}
func makeId(_ namespace: UInt32, _ peer: Int64, _ messageNamespace: Int32 = 0, _ message: Int32) -> MessageId {
    MessageId(peerId: PeerId(namespace: namespace, id: peer), namespace: messageNamespace, id: message)
}

@main struct MessageCleanupTests {
    static func main() {
        let defaults = UserDefaults.standard
        let keys = [MessageDataCleanup.storageKey, "TGExtraAntiSelfDestruct", "TGExtraAntiAutoDelete", "TGExtraAntiRevoke"]
        let previous = keys.map { defaults.object(forKey: $0) }
        defer {
            for (key, value) in zip(keys, previous) {
                if let value = value { defaults.set(value, forKey: key) }
                else { defaults.removeObject(forKey: key) }
            }
        }
        defaults.set(false, forKey: "TGExtraAntiSelfDestruct")
        defaults.set(false, forKey: "TGExtraAntiAutoDelete")
        defaults.removeObject(forKey: MessageDataCleanup.storageKey)
        require(TGExtraMessageCleanupAvailable(), "Resolve actual Swift exports")
        let account = "account-99123"
        let other = "account-99124"
        let postbox = Postbox(account)
        let otherPostbox = Postbox(other)
        let deleted = makeId(0, 42, 0, 10)
        let alive = makeId(0, 42, 0, 11)
        let channel = makeId(2, 77, 0, 10)
        let channelAlive = makeId(2, 77, 0, 12)
        let secret = makeId(3, -2_000_000_000, 2, -100)
        let scheduled = makeId(0, 42, 3, 10)
        let quickReply = makeId(0, 42, 5, 10)
        postbox.messages = [deleted, alive, channel, channelAlive, secret, scheduled, quickReply]
        otherPostbox.messages = [deleted, alive]
        MessageDataCleanup.register(from: Context(postbox))
        MessageDataCleanup.enqueue([
            MessageKey(account: account, peer: 0, id: 10): 1,
            MessageKey(account: account, peer: 0, id: 10, namespace: 5): 1,
            MessageKey(account: account, peer: -1_000_000_000_077, id: 0): 10,
            MessageKey(account: account, peer: -1_998_000_000_000, id: -100, namespace: 2): 1,
            MessageKey(account: account, peer: 42, id: 11): 2,
            MessageKey(account: other, peer: 0, id: 10): 1
        ])
        MessageDataCleanup.start()
        waitFor("Commit active account", { postbox.commits == 1 })
        waitFor("Retain only inactive account's targets", {
            (defaults.dictionary(forKey: MessageDataCleanup.storageKey) ?? [:]).count == 1
        })
        require(postbox.messages == [alive, channelAlive, scheduled], "Remove deleted messages and ranges, preserving live messages and namespaces")
        require(otherPostbox.messages == [deleted, alive], "Inactive account is untouched until registered")
        MessageDataCleanup.register(from: Context(otherPostbox))
        waitFor("Commit inactive account after opening", { otherPostbox.commits == 1 })
        waitFor("Acknowledge journal after commit", { defaults.object(forKey: MessageDataCleanup.storageKey) == nil })
        require(otherPostbox.messages == [alive], "Delete only the requested message from the second account")
        MessageDataCleanup.start()
        Thread.sleep(forTimeInterval: 0.03)
        require(postbox.commits == 1 && otherPostbox.commits == 1, "Completed cleanup is not replayed")
        let sent = makeId(3, 123, 1, -7)
        let received = makeId(3, 123, 2, 8)
        postbox.messages.formUnion([sent, received])
        defaults.set(true, forKey: "TGExtraAntiRevoke")
        let visit = postbox.transaction({ transaction in
            require(secretChatHandleClear(Unmanaged.passUnretained(transaction).toOpaque(), 3, 123) == 1,
                    "Block remote clear and enumerate the actual transaction")
        }, file: "", line: 0).start()
        withExtendedLifetime(visit) { waitFor("Mark both secret message namespaces", { TLParser.markers.count == 2 }) }
        require(TLParser.markers[MessageKey(account: account, peer: -2_000_000_000_123, id: -7, namespace: 1)] == 1 &&
                TLParser.markers[MessageKey(account: account, peer: -2_000_000_000_123, id: 8, namespace: 2)] == 1,
                "History clearing records exact signed IDs and namespaces")
        defaults.set(true, forKey: "TGExtraAntiSelfDestruct")
        let expiredKey = MessageKey(account: account, peer: -2_000_000_000_123, id: 8, namespace: 2)
        let expiry = postbox.transaction({ transaction in
            let pointer = Unmanaged.passUnretained(transaction).toOpaque()
            require(secretChatHandleExpiry(pointer, 0, 123, 0, 11) == 0, "Cloud timers pass through")
            require(secretChatHandleExpiry(pointer, 3, 123, 2, 8) == 1, "Journal the protected expiry before the host clears its index")
        }, file: "", line: 0).start()
        withExtendedLifetime(expiry) {
            waitFor("Persist protected expiry", { defaults.dictionary(forKey: MessageDataCleanup.storageKey)?[expiredKey.storageKey] != nil })
        }
        Thread.sleep(forTimeInterval: 0.03)
        require(postbox.messages.contains(received), "Protected expiry keeps the message")
        require(defaults.dictionary(forKey: MessageDataCleanup.storageKey)?[expiredKey.storageKey] != nil,
                "Expired message survives in the persistent retry journal")
        defaults.set(false, forKey: "TGExtraAntiSelfDestruct")
        defaults.set(false, forKey: "TGExtraAntiAutoDelete")
        waitFor("Resume expiry after disabling protection", { !postbox.messages.contains(received) })
        waitFor("Acknowledge deferred expiry", { defaults.object(forKey: MessageDataCleanup.storageKey) == nil })
        require(postbox.messages.contains(sent), "Deferred expiry preserves other messages")
        MessageDataCleanup.enqueue(TLParser.markers)
        MessageDataCleanup.start()
        waitFor("Cleanup also removes messages retained after remote clear", { !postbox.messages.contains(sent) })
        waitFor("Finish remote-clear cleanup", { defaults.object(forKey: MessageDataCleanup.storageKey) == nil })
        postbox.messages.insert(received)
        defaults.set(true, forKey: "TGExtraAntiAutoDelete")
        MessageDataCleanup.deferExpiry(expiredKey)
        MessageDataCleanup.enqueue([:])
        MessageDataCleanup.deferExpiry(expiredKey)
        MessageDataCleanup.start()
        waitFor("Explicit cleanup overrides timer protection and subsequent expiry callbacks", { !postbox.messages.contains(received) })
        waitFor("Finish explicit expiry cleanup", { defaults.object(forKey: MessageDataCleanup.storageKey) == nil })
        print("PASS local deletion bridge, Swift ABI, remote history clear, deferred expiry, namespaces, inactive accounts and cleanup journal")
    }
}
