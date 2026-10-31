import Foundation

private struct PeerNamespace { let rawValue: UInt32 }
private struct Peer {
    let namespace: PeerNamespace
    init(namespace: Int32) { self.namespace = PeerNamespace(rawValue: UInt32(bitPattern: namespace)) }
}
private struct MessageId { let peerId: Peer }
private struct Message { let id: MessageId }
private enum ContentInfo { case message(Message, Int?); case other }
private struct VideoItem { let contentInfo: ContentInfo? }
private final class Photo: NSObject { let message: Message?; init(_ message: Message?) { self.message = message } }
private final class Video: NSObject { let item: VideoItem?; init(_ info: ContentInfo?) { item = VideoItem(contentInfo: info) } }

@main private enum SecretChatTests {
    static func main() {
        let defaults = UserDefaults.standard
        let keys = ["TGExtraDisableScreenshotNotification", "TGExtraAntiRevoke", "TGExtraAntiSelfDestruct", "TGExtraAntiAutoDelete"]
        let previous = keys.map { defaults.object(forKey: $0) }
        defer {
            for (key, value) in zip(keys, previous) {
                if let value = value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
            }
        }
        for flags in 0..<16 {
            for (i, key) in keys.enumerated() { defaults.set(flags & (1 << i) != 0, forKey: key) }
            for namespace: Int32 in [-1, 0, 1, 2, 3, 4] {
                precondition(secretChatShouldBlock(0, namespace) == (flags & 1 != 0 ? 1 : 0))
                precondition(secretChatShouldBlock(1, namespace) == (flags & 2 != 0 ? 1 : 0))
                precondition(secretChatShouldBlock(2, namespace) == (namespace == 3 && flags & 12 != 0 ? 1 : 0))
                precondition(secretChatShouldBlock(3, namespace) == (namespace == 3 && flags & 4 != 0 ? 1 : 0))
                precondition(secretChatShouldBlock(99, namespace) == 0)
                let message = Message(id: MessageId(peerId: Peer(namespace: namespace)))
                precondition(SecretChatPolicy.isSecretGalleryItem(Photo(message)) == (namespace == 3))
                precondition(SecretChatPolicy.isSecretGalleryItem(Video(.message(message, nil))) == (namespace == 3))
            }
        }
        precondition(!SecretChatPolicy.isSecretGalleryItem(Photo(nil)))
        precondition(!SecretChatPolicy.isSecretGalleryItem(Video(.other)))
        precondition(!SecretChatPolicy.isSecretGalleryItem(Video(nil)))
        print("PASS secret-chat policies: independent settings, cloud isolation, photo/video classification")
    }
}
