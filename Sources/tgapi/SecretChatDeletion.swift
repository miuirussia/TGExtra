import Foundation
import tgapiC

extension TLParser {
    static func recordSecretChatDeletions(transaction: AnyObject, messageIds: UnsafeRawPointer) {
        guard let postbox = HostValueReader.storedField("postbox", in: transaction),
              let account = HostAccountReader.account(in: postbox) else { return }

        // Reviewed arm64 ABI: native Array storage has count at +16, elements
        // at +32. MessageId is PeerId(UInt32, Int64), namespace(Int32), id(Int32).
        let count = messageIds.load(fromByteOffset: 16, as: Int.self)
        guard count > 0 else { return }
        var keys = [MessageKey]()
        for index in 0..<count {
            let element = messageIds.advanced(by: 32 + index * 24)
            let peerNamespace = element.load(as: UInt32.self)
            let peerId = element.load(fromByteOffset: 8, as: Int64.self)
            let namespace = element.load(fromByteOffset: 16, as: Int32.self)
            let id = element.load(fromByteOffset: 20, as: Int32.self)
            // Local (1) is used for sent messages, SecretIncoming (2) for received messages.
            guard peerNamespace == 3, (namespace == 1 || namespace == 2), id != 0,
                  let peer = RenderedMessageReader.peerKey(namespace: 3, id: peerId) else { return }
            keys.append(MessageKey(account: account, peer: peer, id: id, namespace: namespace))
        }

        recordSecretChatDeletionKeys(keys)
    }

    static func recordSecretChatDeletionKeys(_ keys: [MessageKey]) {
        processingLock.lock()
        markerBatchDepth += 1
        for key in keys {
            recordMarker(deletedMarker, id: key.id, peer: key.peer, account: key.account, namespace: key.namespace)
        }
        markerBatchDepth -= 1
        flushMarkers()
        processingLock.unlock()

        let groups = Dictionary(grouping: keys) {
            MessageKey(account: $0.account, peer: $0.peer, id: 0, namespace: $0.namespace)
        }
        DispatchQueue.main.async {
            for (scope, messages) in groups {
                NotificationCenter.default.post(name: NSNotification.Name("TGExtraMessageDeletedRealtime"), object: nil,
                    userInfo: ["ids": messages.map { NSNumber(value: $0.id) }, "account": scope.account,
                               "peer": NSNumber(value: scope.peer), "namespace": NSNumber(value: scope.namespace)])
            }
        }
    }
}

private final class SecretChatClearedMessages {
    let account: String
    var keys = [MessageKey]()
    init(account: String) { self.account = account }
}

@_cdecl("TGExtraSecretChatClearedMessage")
func secretChatClearedMessage(_ context: UnsafeRawPointer, _ message: UnsafeRawPointer) {
    let collector = Unmanaged<SecretChatClearedMessages>.fromOpaque(context).takeUnretainedValue()
    let value = Unmanaged<AnyObject>.fromOpaque(message).takeUnretainedValue()
    guard let identity = HostValueReader.storedField("id", in: value),
          let peerId = HostValueReader.storedField("peerId", in: identity),
          let peer = RenderedMessageReader.peerKey(fromPeerId: peerId),
          let namespace = HostValueReader.storedField("namespace", in: identity).flatMap(HostValueReader.rawNumber),
          namespace == 1 || namespace == 2,
          let id = HostValueReader.storedField("id", in: identity).flatMap(HostValueReader.rawNumber),
          let messageId = Int32(exactly: id), messageId != 0 else { return }
    collector.keys.append(MessageKey(account: collector.account, peer: peer, id: messageId, namespace: Int32(namespace)))
}

@_cdecl("TGExtraSecretChatHandleClear")
public func secretChatHandleClear(_ transaction: UnsafeRawPointer?, _ peerNamespace: UInt32, _ peer: Int64) -> Int32 {
    guard peerNamespace == 3, secretChatShouldBlock(1, 3) != 0 else { return 0 }
    if let transaction = transaction,
       let postbox = HostValueReader.storedField("postbox", in: Unmanaged<AnyObject>.fromOpaque(transaction).takeUnretainedValue()),
       let account = HostAccountReader.account(in: postbox) {
        let collector = SecretChatClearedMessages(account: account)
        withExtendedLifetime(collector) {
            TGExtraVisitLocalMessages(UnsafeMutableRawPointer(mutating: transaction), peerNamespace, peer,
                                     Unmanaged.passUnretained(collector).toOpaque())
        }
        TLParser.recordSecretChatDeletionKeys(collector.keys)
    }
    return 1
}

@_cdecl("TGExtraSecretChatHandleExpiry")
public func secretChatHandleExpiry(_ transaction: UnsafeRawPointer?, _ peerNamespace: UInt32, _ peer: Int64,
                                  _ namespace: Int32, _ id: Int32) -> Int32 {
    guard secretChatShouldBlock(2, Int32(bitPattern: peerNamespace)) != 0 else { return 0 }
    if let transaction = transaction, (namespace == 1 || namespace == 2), id != 0,
       let key = RenderedMessageReader.peerKey(namespace: 3, id: peer),
       let postbox = HostValueReader.storedField("postbox", in: Unmanaged<AnyObject>.fromOpaque(transaction).takeUnretainedValue()),
       let account = HostAccountReader.account(in: postbox) {
        MessageDataCleanup.deferExpiry(MessageKey(account: account, peer: key, id: id, namespace: namespace))
    }
    return 1
}

@_cdecl("TGExtraSecretChatHandleDeletion")
public func secretChatHandleDeletion(_ transaction: UnsafeRawPointer?, _ messageIds: UnsafeRawPointer?) -> Int32 {
    guard secretChatShouldBlock(1, 3) != 0 else { return 0 }
    if let transaction = transaction, let messageIds = messageIds {
        TLParser.recordSecretChatDeletions(transaction: Unmanaged<AnyObject>.fromOpaque(transaction).takeUnretainedValue(),
                                          messageIds: messageIds)
    }
    return 1
}
