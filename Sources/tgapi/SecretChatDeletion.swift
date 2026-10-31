import Foundation

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
                    userInfo: ["ids": messages.map { NSNumber(value: $0.id) }, "account": account,
                               "peer": NSNumber(value: scope.peer), "namespace": NSNumber(value: scope.namespace)])
            }
        }
    }
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
