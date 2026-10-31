import Foundation
import Postbox
import tgapiC

@objc(TLParser) class TLParser: NSObject { static let deletedMarker = 1 }
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
        let previous = defaults.object(forKey: MessageDataCleanup.storageKey)
        defer {
            if let previous = previous { defaults.set(previous, forKey: MessageDataCleanup.storageKey) }
            else { defaults.removeObject(forKey: MessageDataCleanup.storageKey) }
        }
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
        print("PASS local deletion bridge, Swift ABI, channel ranges, secret IDs, namespaces, inactive accounts and cleanup journal")
    }
}
