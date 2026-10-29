import Foundation

private struct OwnAccount {
    let basePath: String
    let peerId: Int64?
}
private struct OwnContext { let account: OwnAccount }
private class ProfileNode {
    let context: OwnContext?
    // This is the displayed peer, which can belong to somebody else.
    let peerId: Int64 = 888
    init(_ account: String, ownId: Int64? = nil) {
        context = OwnContext(account: OwnAccount(basePath: "/accounts/\(account)", peerId: ownId))
    }
}
private final class ProfileSubclass: ProfileNode {}

private struct ProfilePeerId {
    struct Id { let rawValue: Int64 }
    var namespace: Int32 = 0
    let id: Id
}
private struct ProfilePeer {
    var id = ProfilePeerId(id: .init(rawValue: 7331))
    let firstName: String? = "Анна"
    let lastName: String? = "Иванова"
    let username: String? = "anna"
}
private enum ProfileEnginePeer { case user(ProfilePeer), group(ProfilePeer), channel(ProfilePeer) }
private class PeerHeader {
    var peer: ProfileEnginePeer? = .user(ProfilePeer())
}
private final class PeerHeaderSubclass: PeerHeader {}
private final class KVCProfileNode: NSObject {
    @objc let peerId: NSNumber = 7332
    @objc let context = NSObject()
}

private func testProfileBridge() {
    let savedContext = ProfileBridge.sharedContext
    let savedId = defaults.object(forKey: "TGExtraLastKnownUserId")
    defer {
        ProfileBridge.sharedContext = savedContext
        defaults.set(savedId, forKey: "TGExtraLastKnownUserId")
    }
    for (namespace, expected) in [(Int32(0), Int64(7331)), (1, -7331), (2, -1_000_000_007_331)] {
        var peer = ProfilePeer()
        peer.id.namespace = namespace
        let node = PeerHeader()
        node.peer = namespace == 0 ? .user(peer) : namespace == 1 ? .group(peer) : .channel(peer)
        check(ProfileBridge.getPeerIdFromNode(node)?.int64Value == expected, "Profile ids retain their peer namespace")
    }
    var unknownPeer = ProfilePeer()
    unknownPeer.id.namespace = 99
    let unknownHeader = PeerHeader()
    unknownHeader.peer = .user(unknownPeer)
    check(ProfileBridge.getPeerIdFromNode(unknownHeader) == nil, "Unknown peer namespaces cannot become user exceptions")
    let header = PeerHeaderSubclass()
    check(ProfileBridge.getPeerIdFromNode(header) == 7331, "Read peer ids through inherited fields, optionals and enum payloads")
    check(ProfileBridge.getPeerDisplayInfoFromNode(PeerHeader()) ==
          ["name": "Анна Иванова", "username": "anna"], "Read optional profile names and username")
    check(ProfileBridge.getPeerIdFromNode(NSObject()) == nil &&
          ProfileBridge.getPeerDisplayInfoFromNode(NSObject()).isEmpty, "Unknown profile layouts expose no identity")
    ProfileBridge.sharedContext = nil
    let node = KVCProfileNode()
    check(ProfileBridge.getPeerIdFromNode(node) == 7332, "Keep the Objective-C peer lookup path")
    check(ProfileBridge.sharedContext as? NSObject === node.context, "Capture an available host context")
    check(ProfileBridge.debugPeerCandidates(node).contains("kvc.peerId="), "Profile diagnostics remain available to UI hooks")
    ProfileBridge.sharedContext = ProfileNode("account-7333", ownId: 7333).context
    check(ProfileBridge.getCurrentUserId() == 7333, "Read the current user through a wrapped account context")
    ProfileBridge.sharedContext = nil
    check(ProfileBridge.getCurrentUserId() == 7333, "Keep the legacy current-user cache")
}

private func ownUser(_ id: Int64, isSelf: Bool = true) -> Api.User {
    return .user(.init(flags: isSelf ? 1 << 10 : 0, flags2: 0, id: id,
        accessHash: nil, firstName: nil, lastName: nil, username: nil, phone: nil,
        photo: nil, status: nil, botInfoVersion: nil, restrictionReason: nil,
        botInlinePlaceholder: nil, langCode: nil, emojiStatus: nil, usernames: nil,
        storiesMaxId: nil, color: nil, profileColor: nil, botActiveUsers: nil,
        botVerificationIcon: nil, sendPaidMessagesStars: nil, linkedCommunityId: nil))
}

func testOwnUserAccounts() {
    testProfileBridge()
    flags()
    defaults.removeObject(forKey: "TGExtraOwnUserIdsByAccount")
    // Simulate upgrading an installation that has already learned account one.
    defaults.set(101, forKey: "TGExtraLastKnownUserId")
    let first = ProfileSubclass("account-101")
    let second = ProfileNode("account-202")
    let unknown = ProfileNode("account-303")
    ProfileBridge.sharedContext = first.context
    check(ProfileBridge.getOwnUserIdFromNode(second) == nil, "The legacy id cannot identify another account")

    func learn(_ id: Int64, account: String?) {
        let batch = Api.Updates.updates(.init(updates: [], users: [ownUser(888, isSelf: false), ownUser(id)],
                                             chats: [], date: 1234, seq: 1))
        check(strip(serialized(batch), account: account) == nil, "Learning an id does not rewrite a response")
    }
    learn(101, account: "account-101")
    learn(202, account: "account-202")
    check(ProfileBridge.getOwnUserIdFromNode(first) == 101, "Learn the first account with every rewriting feature off")
    check(ProfileBridge.getOwnUserIdFromNode(second) == 202, "Continue learning after the first account is known")
    learn(101, account: "account-101")
    check(ProfileBridge.getOwnUserIdFromNode(second) == 202, "A background response cannot change the visible account")
    ProfileBridge.sharedContext = second.context
    check(ProfileBridge.getOwnUserIdFromNode(first) == 101, "Returning to the first profile ignores a stale shared context")
    check(ProfileBridge.getOwnUserIdFromNode(unknown) == nil, "An unknown account does not inherit another account's id")
    check(ProfileBridge.getOwnUserIdFromNode(NSObject()) == nil, "An unresolved screen has no global id fallback")
    learn(303, account: nil)
    check(ProfileBridge.getOwnUserIdFromNode(unknown) == nil, "Unscoped responses cannot claim an account")

    // users.getUsers is a bare vector and is harvested before normal parsing.
    let vector = Buffer()
    vector.appendInt32(481674261)
    vector.appendInt32(1)
    ownUser(303).serialize(vector, true)
    _ = response(vector.makeData() as NSData, functionID: 227648840, account: "account-303")
    check(ProfileBridge.getOwnUserIdFromNode(unknown) == 303, "Bare vectors use the requesting account too")
    check(ProfileBridge.getOwnUserIdFromNode(first) == 101, "RPC harvesting preserves other accounts")

    let named = ownUser(505, isSelf: false)
    if case let .user(data) = named {
        data.flags |= (1 << 1) | (1 << 2) | (1 << 3)
        data.firstName = "Anna"
        data.lastName = "Ivanova"
        data.username = "anna"
    }
    let lookup = Buffer()
    lookup.appendInt32(481674261)
    lookup.appendInt32(1)
    named.serialize(lookup, true)
    _ = response(lookup.makeData() as NSData, functionID: 227648840)
    check(PeerInfoStore.cachedPeerInfo(forId: 505) == ["name": "Anna Ivanova", "username": "anna"],
          "Wire lookups supply names to the exceptions UI through the shared store")

    let reflected = ProfileSubclass("account-404", ownId: 404)
    check(ProfileBridge.getOwnUserIdFromNode(reflected) == 404, "Reflect the inherited header context's own peer, not its displayed peer")
    check(ProfileBridge.getOwnUserIdFromNode(ProfileNode("account-404")) == 404, "Cache reflected ids by account")
    ProfileBridge.sharedContext = nil
    print("PASS own user ids across accounts, background replies, RPC vectors and inherited profile contexts")
}

func testRestoredOwnUserAccounts() {
    defaults.set(["account-101": 101, "account-202": 202], forKey: "TGExtraOwnUserIdsByAccount")
    defaults.set(999, forKey: "TGExtraLastKnownUserId")
    check(ProfileBridge.getOwnUserIdFromNode(ProfileNode("account-101")) == 101, "Restore the first account's own id")
    check(ProfileBridge.getOwnUserIdFromNode(ProfileNode("account-202")) == 202, "Restore the second account's own id")
    check(ProfileBridge.getOwnUserIdFromNode(ProfileNode("account-303")) == nil, "Do not migrate an unscoped legacy id to an unknown account")
}
