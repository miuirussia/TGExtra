import Foundation
import SwiftSignalKit

public struct PeerId: Hashable {
    public let namespace: UInt32
    public let id: Int64
    public init(namespace: UInt32, id: Int64) { self.namespace = namespace; self.id = id }
}
public struct MessageId: Hashable {
    public let peerId: PeerId
    public let namespace: Int32
    public let id: Int32
    public init(peerId: PeerId, namespace: Int32, id: Int32) {
        self.peerId = peerId; self.namespace = namespace; self.id = id
    }
}
public protocol Media {}
public final class Message {
    public let id: MessageId
    public init(_ id: MessageId) { self.id = id }
}
public final class Transaction {
    private let postbox: Postbox
    init(_ postbox: Postbox) { self.postbox = postbox }
    public func deleteMessages(_ ids: [MessageId], forEachMedia: ((Media) -> Void)?) {
        postbox.messages.subtract(ids)
    }
    public func deleteMessagesWithGlobalIds(_ ids: [Int32], forEachMedia: ((Media) -> Void)?) {
        postbox.messages = postbox.messages.filter { $0.peerId.namespace >= 2 || $0.namespace != 0 || !ids.contains($0.id) }
    }
    public func deleteMessagesInRange(peerId: PeerId, namespace: Int32, minId: Int32, maxId: Int32, forEachMedia: ((Media) -> Void)?) {
        postbox.messages = postbox.messages.filter { $0.peerId != peerId || $0.namespace != namespace || $0.id < minId || $0.id > maxId }
    }
    public func withAllMessages(peerId: PeerId, namespace: Int32? = nil, _ f: (Message) -> Bool) {
        precondition(namespace == nil)
        for id in postbox.messages where id.peerId == peerId {
            if !f(Message(id)) { break }
        }
    }
}
public final class Postbox {
    public let basePath: String
    public var accountPath: String { basePath }
    public var messages = Set<MessageId>()
    public var commits = 0
    public init(_ account: String) { basePath = "/accounts/\(account)/postbox" }
    public func transaction<T>(userInteractive: Bool = false, ignoreDisabled: Bool = false, _ body: @escaping (Transaction) -> T, file: String = #file, line: Int = #line) -> Signal<T, NoError> {
        precondition(file.isEmpty && line == 0)
        return Signal { next, completed in
            DispatchQueue.global().async {
                next(body(Transaction(self)))
                self.commits += 1
                completed()
            }
        }
    }
}
