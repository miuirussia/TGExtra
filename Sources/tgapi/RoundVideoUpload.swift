import Foundation

extension TLParser {
    private static weak var videoConversionChat: AnyObject?

    @objc static func registerVideoConversionChat(_ controller: AnyObject) {
        videoConversionChat = controller
    }

    @objc static func roundVideoChatSupported() -> Bool {
        guard let controller = videoConversionChat,
              let location = HostValueReader.storedField("chatLocation", in: controller) else { return true }
        let mirror = Mirror(reflecting: HostValueReader.unwrapOptional(location))
        guard mirror.displayStyle == .enum, let peer = mirror.children.first, peer.label == "peer" else { return true }
        let payload = peer.value
        let peerId = Mirror(reflecting: payload).displayStyle == .tuple ?
            (HostValueReader.storedField("peerId", in: payload) ?? HostValueReader.storedField("id", in: payload) ?? payload) : payload
        let namespace = HostValueReader.storedField("namespace", in: peerId).flatMap(HostValueReader.rawNumber)
        return namespace != 3
    }

    static let roundVideoQueue = DispatchQueue(label: "com.tgextra.roundVideoUploads")
    static var roundVideoUploads = [String: Double]()
    static var roundVideoOrder = [String]()

    @objc static func registerRoundVideoUpload(withFileName fileName: String, duration: Double) {
        guard !fileName.isEmpty, duration.isFinite, duration > 0, duration <= 60.1 else { return }
        roundVideoQueue.sync {
            if roundVideoUploads[fileName] == nil { roundVideoOrder.append(fileName) }
            roundVideoUploads[fileName] = duration
            while roundVideoOrder.count > 32 {
                roundVideoUploads.removeValue(forKey: roundVideoOrder.removeFirst())
            }
        }
    }

    static func roundVideoMedia(from media: Api.InputMedia) -> Api.InputMedia? {
        guard MessagePatches.Settings().videoToRound,
              case let .inputMediaUploadedDocument(upload) = media,
              upload.mimeType == "video/mp4" else { return nil }
        for attribute in upload.attributes {
            guard case let .documentAttributeFilename(name) = attribute,
                  let duration = roundVideoQueue.sync(execute: { roundVideoUploads[name.fileName] }) else { continue }
            // Telegram's standalone round_message and supports_streaming flags are absent from TLS1.
            let video = Api.DocumentAttribute.documentAttributeVideo(.init(
                flags: (1 << 0) | (1 << 1), duration: duration, w: 384, h: 384,
                preloadPrefixSize: nil, videoStartTs: nil, videoCodec: nil))
            guard MessagePatches.replaceRoundVideoAttributes(in: media.record, attributes: [video],
                                                              registeredUpload: true) else { return nil }
            return media
        }
        return nil
    }
}
