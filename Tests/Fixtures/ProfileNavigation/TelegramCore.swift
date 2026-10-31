import Postbox

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
