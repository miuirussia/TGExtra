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

private func ownUser(_ id: Int64, isSelf: Bool = true) -> Api.User {
    return .user(.init(flags: isSelf ? 1 << 10 : 0, flags2: 0, id: id,
        accessHash: nil, firstName: nil, lastName: nil, username: nil, phone: nil,
        photo: nil, status: nil, botInfoVersion: nil, restrictionReason: nil,
        botInlinePlaceholder: nil, langCode: nil, emojiStatus: nil, usernames: nil,
        storiesMaxId: nil, color: nil, profileColor: nil, botActiveUsers: nil,
        botVerificationIcon: nil, sendPaidMessagesStars: nil, linkedCommunityId: nil))
}

func testOwnUserAccounts() {
    flags()
    defaults.removeObject(forKey: "TGExtraOwnUserIdsByAccount")
    // Simulate upgrading an installation that has already learned account one.
    defaults.set(101, forKey: "TGExtraLastKnownUserId")
    let first = ProfileSubclass("account-101")
    let second = ProfileNode("account-202")
    let unknown = ProfileNode("account-303")
    TLParser.sharedContext = first.context
    check(TLParser.getOwnUserIdFromNode(second) == nil, "The legacy id cannot identify another account")

    func learn(_ id: Int64, account: String?) {
        let batch = Api.Updates.updates(.init(updates: [], users: [ownUser(888, isSelf: false), ownUser(id)],
                                             chats: [], date: 1234, seq: 1))
        check(strip(serialized(batch), account: account) == nil, "Learning an id does not rewrite a response")
    }
    learn(101, account: "account-101")
    learn(202, account: "account-202")
    check(TLParser.getOwnUserIdFromNode(first) == 101, "Learn the first account with every rewriting feature off")
    check(TLParser.getOwnUserIdFromNode(second) == 202, "Continue learning after the first account is known")
    learn(101, account: "account-101")
    check(TLParser.getOwnUserIdFromNode(second) == 202, "A background response cannot change the visible account")
    TLParser.sharedContext = second.context
    check(TLParser.getOwnUserIdFromNode(first) == 101, "Returning to the first profile ignores a stale shared context")
    check(TLParser.getOwnUserIdFromNode(unknown) == nil, "An unknown account does not inherit another account's id")
    check(TLParser.getOwnUserIdFromNode(NSObject()) == nil, "An unresolved screen has no global id fallback")
    learn(303, account: nil)
    check(TLParser.getOwnUserIdFromNode(unknown) == nil, "Unscoped responses cannot claim an account")

    // users.getUsers is a bare vector and is harvested before normal parsing.
    let vector = Buffer()
    vector.appendInt32(481674261)
    vector.appendInt32(1)
    ownUser(303).serialize(vector, true)
    _ = response(vector.makeData() as NSData, functionID: 227648840, account: "account-303")
    check(TLParser.getOwnUserIdFromNode(unknown) == 303, "Bare vectors use the requesting account too")
    check(TLParser.getOwnUserIdFromNode(first) == 101, "RPC harvesting preserves other accounts")

    let reflected = ProfileSubclass("account-404", ownId: 404)
    check(TLParser.getOwnUserIdFromNode(reflected) == 404, "Reflect the inherited header context's own peer, not its displayed peer")
    check(TLParser.getOwnUserIdFromNode(ProfileNode("account-404")) == 404, "Cache reflected ids by account")
    TLParser.sharedContext = nil
    print("PASS own user ids across accounts, background replies, RPC vectors and inherited profile contexts")
}

func testRestoredOwnUserAccounts() {
    defaults.set(["account-101": 101, "account-202": 202], forKey: "TGExtraOwnUserIdsByAccount")
    defaults.set(999, forKey: "TGExtraLastKnownUserId")
    check(TLParser.getOwnUserIdFromNode(ProfileNode("account-101")) == 101, "Restore the first account's own id")
    check(TLParser.getOwnUserIdFromNode(ProfileNode("account-202")) == 202, "Restore the second account's own id")
    check(TLParser.getOwnUserIdFromNode(ProfileNode("account-303")) == nil, "Do not migrate an unscoped legacy id to an unknown account")
}
