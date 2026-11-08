import Foundation
import Postbox
import TelegramCore
import SwiftSignalKit
import tgapiC

private struct Context {
    let account: Account
    let engine: TelegramEngine
    init(postbox: Postbox) {
        account = Account(postbox: postbox)
        engine = TelegramEngine(account: account)
    }
}
private struct ProfileData { let peer: EnginePeer? }
private struct Interaction { let openPeerInfo: (EnginePeer, Bool) -> Void }
private final class NavigationProbe: NSObject {
    @objc var viewControllers = [NSObject()]
}
private final class ControllerProbe: NSObject {
    @objc let navigationController: NavigationProbe
    init(_ navigation: NavigationProbe) { navigationController = navigation }
}
private class ProfileNode {
    let context: Context
    let data: ProfileData?
    let _interaction: Interaction?
    let controller: ControllerProbe?
    init(_ postbox: Postbox, navigation: NavigationProbe = NavigationProbe(),
         action: @escaping (EnginePeer, Bool) -> Void) {
        context = Context(postbox: postbox)
        data = ProfileData(peer: .user(TelegramUser(1)))
        _interaction = Interaction(openPeerInfo: action)
        controller = ControllerProbe(navigation)
    }
}
private final class InheritedProfileNode: ProfileNode {}
private struct ProfileHeader {
    let context: Context
    let peer: EnginePeer?
}

private func waitFor(_ condition: () -> Bool, timeout: TimeInterval = 5) {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() && Date() < deadline {
        RunLoop.current.run(until: Date().addingTimeInterval(0.01))
    }
    precondition(condition(), "Timed out waiting for profile lookup")
}

precondition(TGExtraProfileLookupAvailable(), "Resolve real Swift exports")
precondition(TGExtraProfileRefreshAvailable(), "Resolve native server lookup and cancellation exports")
let forceServerKey = "TGExtraForceProfileServerLookup"
UserDefaults.standard.removeObject(forKey: forceServerKey)
TGExtraClearLog()
let first = Postbox(), second = Postbox()
let id: Int64 = 7_331_000_001
first.peers[PeerId(namespace: 0, id: id)] = TelegramUser(id)
weak var loadedUser = first.peers[PeerId(namespace: 0, id: id)] as? TelegramUser
second.peers[PeerId(namespace: 0, id: 42)] = TelegramUser(42)
var opened = [Int64]()
var opener: (() -> Bool)?
var completed = false
private let navigation = NavigationProbe()
private var node: ProfileNode? = InheritedProfileNode(first, navigation: navigation) { peer, isMember in
    precondition(Thread.isMainThread, "Native profile action runs on the main thread")
    precondition(!isMember, "Open a regular profile")
    opened.append(peer.id)
    navigation.viewControllers.append(NSObject())
}
private weak var retainedNode = node
ProfileNavigation.loadProfile(peerId: NSNumber(value: id), fromNode: node!) { action in
    precondition(Thread.isMainThread)
    opener = action
    completed = true
}
node = nil
waitFor { completed }
precondition(opened.isEmpty && opener != nil, "Prepare the profile before dismissing settings")
precondition(retainedNode != nil, "Keep the native source alive through dismissal")
first.peers.removeAll()
precondition(loadedUser != nil, "The prepared profile owns the native peer until navigation finishes")
precondition(opener?() == true, "Confirm that the native profile was pushed")
precondition(opened == [id], "Invoke the native callback with the 64-bit user ID")
opener = nil
waitFor { retainedNode == nil && loadedUser == nil && DisposableProbe.liveTokens == 0 }
precondition(TGExtraReadLog().isEmpty, "Successful navigation must not log a failure")

private let otherNode = ProfileNode(second) { _, _ in preconditionFailure("Wrong account") }
completed = false
ProfileNavigation.loadProfile(peerId: NSNumber(value: id), fromNode: otherNode) { action in
    precondition(Thread.isMainThread && action == nil, "Do not resolve a user from a different account")
    completed = true
}
waitFor { completed }
private let refusingNode = ProfileNode(second) { _, _ in }
completed = false
ProfileNavigation.loadProfile(peerId: 42, fromNode: refusingNode) { action in
    precondition(action?() == false, "Report when the native handler does not open a profile")
    completed = true
}
waitFor { completed }
for value in [Int64(0), -1] {
    completed = false
    ProfileNavigation.loadProfile(peerId: NSNumber(value: value), fromNode: otherNode) { action in
        precondition(action == nil)
        completed = true
    }
    precondition(completed, "Reject invalid IDs before starting a transaction")
}
completed = false
ProfileNavigation.loadProfile(peerId: 42, fromNode: NSObject()) { action in
    precondition(action == nil)
    completed = true
}
precondition(completed, "An unsupported screen has no native navigation action")
struct ChangedInteraction {
    let openPeerInfo: (Int64, Bool) -> Void = { _, _ in preconditionFailure("Changed host signature") }
}
struct ChangedScreen { let _interaction = ChangedInteraction() }
completed = false
ProfileNavigation.loadProfile(peerId: 42, fromNode: ChangedScreen()) { action in
    precondition(action == nil)
    completed = true
}
precondition(completed, "A changed host callback signature is rejected before invoking it")
precondition(second.transactions == 2)

// A missing peer must not accidentally open a group with the same numeric ID.
second.peers[PeerId(namespace: 2, id: id)] = TelegramUser(id)
completed = false
ProfileNavigation.loadProfile(peerId: NSNumber(value: id), fromNode: otherNode) { action in
    precondition(action == nil)
    completed = true
}
waitFor { completed }
let log = TGExtraReadLog() ?? ""
for entry in [
    "peer=7331000001 reason=server lookup by ID failed; user inaccessible or access hash required",
    "peer=42 reason=native profile action did not open a controller",
    "peer=0 reason=invalid user ID",
    "peer=-1 reason=invalid user ID",
    "peer=42 reason=native profile action missing",
    "peer=42 reason=unsupported native profile action signature:",
] {
    precondition(log.contains(entry), "Missing profile failure diagnostic: \(entry)\n\(log)")
}
precondition(log.components(separatedBy: "Ghost profile: open failed").count == 8,
             "Write one diagnostic for each failed navigation")
print("PASS native profiles, account isolation, lifetime and persisted failure logs with user IDs and reasons")

// A user absent from this account's Postbox can be recovered strictly by ID.
TGExtraClearLog()
let remoteId: Int64 = 5_365_271_490
private let remoteNavigation = NavigationProbe()
private let remoteNode = ProfileNode(second, navigation: remoteNavigation) { peer, _ in
    precondition(peer.id == remoteId && Thread.isMainThread)
    remoteNavigation.viewControllers.append(NSObject())
}
remoteNode.context.account.remoteUsers[remoteId] = TelegramUser(remoteId)
completed = false
ProfileNavigation.loadProfile(peerId: NSNumber(value: remoteId), fromNode: remoteNode) { action in
    precondition(Thread.isMainThread && action != nil)
    opener = action
    completed = true
}
waitFor { completed }
precondition(remoteNode.context.account.refreshes == [remoteId], "Fetch the exact 64-bit ID once")
precondition(remoteNavigation.viewControllers.count == 1, "Keep settings until lookup finishes")
precondition(opener?() == true)
opener = nil
waitFor { DisposableProbe.liveTokens == 0 }
precondition(!TGExtraReadLog().contains("open failed"))
precondition(TGExtraReadLog().contains("local=missing accessHash=missing"),
             "Distinguish an absent local peer and missing hash from an inaccessible server user")

// A mismatched server result must never navigate to another ID or loop.
let missingId: Int64 = remoteId + 1
remoteNode.context.account.remoteUsers[missingId] = TelegramUser(remoteId + 2)
completed = false
ProfileNavigation.loadProfile(peerId: NSNumber(value: missingId), fromNode: remoteNode) { action in
    precondition(action == nil)
    completed = true
}
waitFor { completed }
precondition(remoteNode.context.account.refreshes == [remoteId, missingId])
precondition(TGExtraReadLog().contains("user not found in source account after server lookup by ID"))
waitFor { DisposableProbe.liveTokens == 0 }
print("PASS ID-only server recovery, exact-ID verification and disposable cleanup")

remoteNode.context.account.deferRefresh = true
completed = false
var completions = 0
ProfileNavigation.loadProfile(peerId: 999, fromNode: remoteNode) { action in
    precondition(action == nil && Thread.isMainThread)
    completions += 1
    completed = true
}
waitFor { remoteNode.context.account.pendingCompletion != nil }
let lateCompletion = remoteNode.context.account.pendingCompletion
waitFor({ completed }, timeout: 20)
precondition(remoteNode.context.account.cancellations == 1)
precondition(remoteNode.context.account.pendingCompletion == nil)
precondition(TGExtraReadLog().contains("peer=999 reason=server lookup by ID timed out"))
lateCompletion?()
RunLoop.current.run(until: Date().addingTimeInterval(0.05))
precondition(completions == 1, "A late server response must not finish navigation twice")
waitFor { DisposableProbe.liveTokens == 0 }
print("PASS server timeout cancels the request and ignores late completion")

// A real server requires the personal access hash for ordinary user IDs.
let hashId: Int64 = 5_365_271_490
let hash: Int64 = -8_765_432_109_876_543_210
let hashUser = TelegramUser(hashId, accessHash: .personal(hash))
let hashPostbox = Postbox()
private let hashNavigation = NavigationProbe()
private let hashNode = ProfileNode(hashPostbox, navigation: hashNavigation) { peer, _ in
    precondition(peer.id == hashId)
    hashNavigation.viewControllers.append(NSObject())
}
let hashStoreKey = "TGExtraProfileAccessHashesByAccount"
UserDefaults.standard.removeObject(forKey: hashStoreKey)
ProfileNavigation.rememberProfile(peerId: NSNumber(value: hashId),
    fromNode: ProfileHeader(context: hashNode.context, peer: .user(hashUser)))
precondition(UserDefaults.standard.dictionary(forKey: hashStoreKey) != nil,
             "Persist personal access hashes across launches, outside exported settings")
hashNode.context.account.remoteUsers[hashId] = hashUser
hashNode.context.account.requiredAccessHashes[hashId] = hash
completed = false
ProfileNavigation.loadProfile(peerId: NSNumber(value: hashId), fromNode: hashNode) { action in
    precondition(action?() == true, "Recover a missing peer with its saved 64-bit personal access hash")
    completed = true
}
waitFor { completed }
precondition(hashNode.context.account.refreshes == [hashId])
precondition(TGExtraReadLog().contains("local=missing accessHash=saved"),
             "Report which recovery credential was available without logging its value")
precondition(!TGExtraReadLog().contains(String(hash)), "Access hashes must not appear in diagnostics")

// A lower-quality min hash, wrong peer or unsupported header must not overwrite it.
for peer in [EnginePeer.user(TelegramUser(hashId, accessHash: .genericPublic(123))),
             .user(TelegramUser(hashId + 1, accessHash: .personal(456)))] {
    ProfileNavigation.rememberProfile(peerId: NSNumber(value: hashId),
        fromNode: ProfileHeader(context: hashNode.context, peer: peer))
}
ProfileNavigation.rememberProfile(peerId: NSNumber(value: hashId), fromNode: NSObject())
hashPostbox.peers.removeAll()
completed = false
ProfileNavigation.loadProfile(peerId: NSNumber(value: hashId), fromNode: hashNode) { action in
    precondition(action?() == true, "Keep the full hash when a min user is displayed later")
    completed = true
}
waitFor { completed }

// Global exceptions must never reuse access hashes captured in another account.
let isolatedPostbox = Postbox()
private let isolatedNode = ProfileNode(isolatedPostbox) { _, _ in preconditionFailure("Another account") }
isolatedNode.context.account.remoteUsers[hashId] = hashUser
isolatedNode.context.account.requiredAccessHashes[hashId] = hash
completed = false
ProfileNavigation.loadProfile(peerId: NSNumber(value: hashId), fromNode: isolatedNode) { action in
    precondition(action == nil, "A saved access hash cannot cross account boundaries")
    completed = true
}
waitFor { completed }
UserDefaults.standard.removeObject(forKey: hashStoreKey)
waitFor { DisposableProbe.liveTokens == 0 }
print("PASS personal access hash recovery, persistence, min-hash protection and account isolation")

// The diagnostic switch exercises the server even while a usable local peer exists.
UserDefaults.standard.set(true, forKey: forceServerKey)
TGExtraClearLog()
let refreshedUser = TelegramUser(hashId, accessHash: .personal(hash))
hashNode.context.account.remoteUsers[hashId] = refreshedUser
let previousRefreshes = hashNode.context.account.refreshes.count
let previousTransactions = hashPostbox.transactions
completed = false
ProfileNavigation.loadProfile(peerId: NSNumber(value: hashId), fromNode: hashNode) { action in
    precondition(action?() == true, "Force remote lookup before opening an already cached peer")
    completed = true
}
waitFor { completed }
precondition(hashNode.context.account.refreshes.count == previousRefreshes + 1,
             "Perform exactly one server lookup, without a refresh loop")
precondition(hashPostbox.transactions == previousTransactions + 2,
             "Read the local peer for its hash, then read again after server refresh")
precondition(hashPostbox.peers[refreshedUser.id] === refreshedUser, "Open the freshly fetched peer")
precondition(TGExtraReadLog().contains("local=bypassed accessHash=saved"))
precondition(TGExtraReadLog().contains("server lookup by ID succeeded"))
precondition(!TGExtraReadLog().contains(String(hash)))

// A failed forced lookup must stay visible rather than succeed using the cache.
hashNode.context.account.remoteUsers.removeValue(forKey: hashId)
let previousOpens = hashNavigation.viewControllers.count
completed = false
ProfileNavigation.loadProfile(peerId: NSNumber(value: hashId), fromNode: hashNode) { action in
    precondition(action == nil, "Report a server failure even when a cached peer exists")
    completed = true
}
waitFor { completed }
precondition(hashNavigation.viewControllers.count == previousOpens)
precondition(hashPostbox.peers[refreshedUser.id] === refreshedUser, "Never delete the real cached peer")

UserDefaults.standard.set(false, forKey: forceServerKey)
let refreshesBeforeCachedOpen = hashNode.context.account.refreshes.count
completed = false
ProfileNavigation.loadProfile(peerId: NSNumber(value: hashId), fromNode: hashNode) { action in
    precondition(action?() == true, "Disabling the switch immediately restores ordinary cached navigation")
    completed = true
}
waitFor { completed }
precondition(hashNode.context.account.refreshes.count == refreshesBeforeCachedOpen)
UserDefaults.standard.removeObject(forKey: forceServerKey)
UserDefaults.standard.removeObject(forKey: hashStoreKey)
waitFor { DisposableProbe.liveTokens == 0 }
print("PASS forced server lookup toggle, cached hash recovery, errors, unchanged local peers and immediate off/on behavior")
