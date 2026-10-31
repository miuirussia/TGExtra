import Foundation
import SwiftSignalKit

public struct PeerId: Hashable {
#if FUTURE_PEER_ID_LAYOUT
    public let namespace: UInt64
#else
    public let namespace: UInt32
#endif
    public let id: Int64
    public init(namespace: UInt32, id: Int64) {
        self.namespace = .init(namespace)
        self.id = id
    }
}
public protocol Peer: AnyObject { var id: PeerId { get } }
public final class Transaction {
    let postbox: Postbox
    init(_ postbox: Postbox) { self.postbox = postbox }
    public func getPeer(_ id: PeerId) -> Peer? { postbox.peers[id] }
}
public final class Postbox {
    public var peers = [PeerId: Peer]()
    public var transactions = 0
    public init() {}
    public func transaction<T>(userInteractive: Bool = false, ignoreDisabled: Bool = false,
                               _ body: @escaping (Transaction) -> T,
                               file: String = #file, line: Int = #line) -> Signal<T, NoError> {
        precondition(!userInteractive && !ignoreDisabled && file.isEmpty && line == 0)
        return Signal { next, completed in
            DispatchQueue.global().async {
                self.transactions += 1
                next(body(Transaction(self)))
                completed()
            }
        }
    }
}
