import Foundation
import Postbox
import TelegramCore
import SwiftSignalKit
import tgapiC

private struct Account { let postbox: Postbox }
private struct Context { let account: Account }
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
        context = Context(account: Account(postbox: postbox))
        data = ProfileData(peer: .user(TelegramUser(1)))
        _interaction = Interaction(openPeerInfo: action)
        controller = ControllerProbe(navigation)
    }
}
private final class InheritedProfileNode: ProfileNode {}

private func waitFor(_ condition: () -> Bool) {
    let deadline = Date().addingTimeInterval(5)
    while !condition() && Date() < deadline {
        RunLoop.current.run(until: Date().addingTimeInterval(0.01))
    }
    precondition(condition(), "Timed out waiting for profile lookup")
}

precondition(TGExtraProfileLookupAvailable(), "Resolve real Swift exports")
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
    "peer=7331000001 reason=user not found in source account",
    "peer=42 reason=native profile action did not open a controller",
    "peer=0 reason=invalid user ID",
    "peer=-1 reason=invalid user ID",
    "peer=42 reason=native profile action missing",
    "peer=42 reason=unsupported native profile action signature:",
] {
    precondition(log.contains(entry), "Missing profile failure diagnostic: \(entry)")
}
precondition(log.components(separatedBy: "Ghost profile: open failed").count == 8,
             "Write one diagnostic for each failed navigation")
print("PASS native profiles, account isolation, lifetime and persisted failure logs with user IDs and reasons")
