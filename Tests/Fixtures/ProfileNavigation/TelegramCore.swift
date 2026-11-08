import Postbox
import SwiftSignalKit

public final class TelegramUser: Peer {
    public let id: PeerId
    public init(_ id: Int64) { self.id = PeerId(namespace: 0, id: id) }
}
public enum EnginePeer {
    case user(TelegramUser)
    case legacyGroup(TelegramUser)
    case channel(TelegramUser)
    case secretChat(TelegramUser)
#if FUTURE_PROFILE_LAYOUT
    case future(Int64, Int64)
#endif
    public init(_ peer: Peer) { self = .user(peer as! TelegramUser) }
    public var id: Int64 {
        switch self {
        case let .user(user), let .legacyGroup(user), let .channel(user), let .secretChat(user):
            return user.id.id
#if FUTURE_PROFILE_LAYOUT
        case let .future(id, _): return id
#endif
        }
    }
}

public enum PeerReference {
    case user(id: Int64, accessHash: Int64)
    case group(id: Int64)
    case channel(id: Int64, accessHash: Int64)
#if FUTURE_REFERENCE_LAYOUT
    case future(Int64, Int64, Int64)
#endif
}
public enum UpdatedRemotePeerError { case generic }
public final class Account {
    public let postbox: Postbox
    public var remoteUsers = [Int64: TelegramUser]()
    public var refreshes = [Int64]()
    public var deferRefresh = false
    public var pendingCompletion: (() -> Void)?
    public var cancellations = 0
    public init(postbox: Postbox) { self.postbox = postbox }
}
public final class TelegramEngine {
    public final class Peers {
        let account: Account
        init(account: Account) { self.account = account }
        public func updatedRemotePeer(peer: PeerReference) -> Signal<EnginePeer, UpdatedRemotePeerError> {
            guard case let .user(id, accessHash) = peer else { preconditionFailure("Only resolve a user ID") }
            precondition(accessHash == 0)
            account.refreshes.append(id)
            return Signal(cancellable: { next, error, completed in
                if self.account.deferRefresh {
                    self.account.pendingCompletion = completed
                    return {
                        self.account.pendingCompletion = nil
                        self.account.cancellations += 1
                    }
                }
                if let user = self.account.remoteUsers[id] {
                    self.account.postbox.peers[user.id] = user
                    next(.user(user))
                    completed()
                } else {
                    error(.generic)
                }
                return {}
            })
        }
    }
    public let account: Account
    public lazy var peers = Peers(account: account)
    public init(account: Account) { self.account = account }
}
