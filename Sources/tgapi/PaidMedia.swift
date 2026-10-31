import Foundation

@objc(TGExtraPaidMediaFile)
final class PaidMediaFile: NSObject {
    private static let galleryItems = NSMapTable<AnyObject, AnyObject>.weakToWeakObjects()
    @objc let context: NSObject?
    @objc let masterDatacenterId: Int
    @objc let datacenterId: Int
    @objc let size: Int64
    @objc let video: Bool
    @objc let nativeOnly: Bool
    @objc let cachePath: String?
    private var nativeItem: AnyObject?
    private let location: Api.InputFileLocation?

    private init(context: NSObject?, master: Int, dc: Int, size: Int64, video: Bool,
                 cachePath: String?, location: Api.InputFileLocation?, nativeOnly: Bool = false) {
        self.context = context
        self.masterDatacenterId = master
        self.datacenterId = dc
        self.size = size
        self.video = video
        self.nativeOnly = nativeOnly
        self.cachePath = cachePath
        self.location = location
    }

    private static func unwrapped(_ value: Any) -> Any? {
        let mirror = Mirror(reflecting: value)
        return mirror.displayStyle == .optional ? mirror.children.first?.value : value
    }

    static func field(_ value: Any, _ name: String) -> Any? {
        guard let value = unwrapped(value) else { return nil }
        var mirror: Mirror? = Mirror(reflecting: value)
        while let current = mirror {
            if let child = current.children.first(where: { $0.label == name }) {
                return unwrapped(child.value)
            }
            mirror = current.superclassMirror
        }
        return nil
    }

    private static func named(_ value: Any, _ name: String) -> Bool {
        String(reflecting: type(of: value)).split(separator: ".").last == Substring(name)
    }

    private static func associated(_ value: Any, case name: String) -> Any? {
        let mirror = Mirror(reflecting: value)
        guard mirror.displayStyle == .enum, let child = mirror.children.first,
              child.label == name else { return nil }
        let payload = Mirror(reflecting: child.value)
        return payload.displayStyle == .tuple && payload.children.count == 1
            ? payload.children.first?.value : child.value
    }

    private static func selectedMedia(message: Any, subject: Any?) -> Any? {
        guard let media = field(message, "media") as? [Any],
              let paid = media.first(where: { named($0, "TelegramMediaPaidContent") }),
              let extended = field(paid, "extendedMedia") as? [Any] else { return nil }
        let index: Int
        if let subject = subject {
            guard let selected = associated(subject, case: "paidMediaIndex") as? Int else { return nil }
            index = selected
        } else { index = 0 }
        guard extended.indices.contains(index) else { return nil }
        return associated(extended[index], case: "full")
    }

    @objc(isUnlockedPaidItem:)
    static func isUnlockedPaidItem(_ itemNode: AnyObject) -> Bool {
        if let message = field(itemNode, "message") {
            return selectedMedia(message: message, subject: field(itemNode, "mediaSubject")) != nil
        }
        if let item = field(itemNode, "item") {
            guard let info = field(item, "contentInfo"), let payload = associated(info, case: "message"),
                  let message = field(payload, ".0") else { return false }
            return selectedMedia(message: message, subject: field(payload, ".1")) != nil
        }
        if let footer = field(itemNode, "footerContentNode"), let message = field(footer, "currentMessage") {
            return selectedMedia(message: message, subject: field(footer, "mediaSubject")) != nil
        }
        return false
    }

    @objc(bindGalleryItem:)
    static func bindGalleryItem(_ item: AnyObject) {
        guard Thread.isMainThread, let footer = field(item, "footerContentNode") else { return }
        galleryItems.setObject(item, forKey: footer as AnyObject)
    }

    @objc func beginNativeDownload() -> Bool {
        if nativeOnly {
            guard Thread.isMainThread else { return false }
            // Secret photo galleries fetch automatically. Secret videos opened
            // from the preview may already be using a completed local resource.
            if let item = nativeItem {
                guard let footer = Self.field(item, "footerContentNode"),
                      Self.file(footer: footer as AnyObject)?.cachePath == cachePath else { return false }
                if let controls = Self.field(item, "fetchControls"),
                   let fetch = Self.field(controls, "fetch") as? () -> Void {
                    if let status = Self.field(item, "fetchStatus"),
                       Self.associated(status, case: "Fetching") != nil { return true }
                    fetch()
                }
            }
            return cachePath != nil
        }
        guard Thread.isMainThread, video, let item = nativeItem,
              let footer = Self.field(item, "footerContentNode"),
              let current = Self.file(footer: footer as AnyObject), current.cachePath == cachePath,
              let controls = Self.field(item, "fetchControls"),
              let fetch = Self.field(controls, "fetch") as? () -> Void else { return false }
        if let status = Self.field(item, "fetchStatus"),
           Self.associated(status, case: "Fetching") != nil { return true }
        fetch()
        return true
    }

    @objc var nativeDownloadProgress: NSNumber? {
        guard Thread.isMainThread, let item = nativeItem, let status = Self.field(item, "fetchStatus"),
              let payload = Self.associated(status, case: "Fetching"),
              let progress = Self.field(payload, "progress") as? Float else { return nil }
        return NSNumber(value: progress)
    }

    @objc(fileFromFooterNode:)
    static func file(footer: AnyObject) -> PaidMediaFile? {
        let previewMessage = field(footer, "messageView").flatMap { field($0, "message") }
        guard let message = field(footer, "currentMessage") ?? previewMessage else { return nil }
        if SecretChatPolicy.isSecretMessage(message) {
            return secretFile(footer: footer, message: message)
        }
        guard let full = selectedMedia(message: message, subject: field(footer, "mediaSubject")),
              let accountContext = field(footer, "context"), let account = field(accountContext, "account"),
              let network = field(account, "network"), let context = field(network, "context") as? NSObject,
              let master = field(network, "datacenterId") as? Int, master > 0 else { return nil }

        let resource: Any
        let video: Bool
        if named(full, "TelegramMediaImage"), let representations = field(full, "representations") as? [Any] {
            let photos = representations.filter {
                guard let r = field($0, "resource") else { return false }
                return named(r, "CloudPhotoSizeMediaResource")
            }
            func area(_ representation: Any) -> Int64 {
                guard let dimensions = field(representation, "dimensions"),
                      let w = field(dimensions, "width") as? Int32,
                      let h = field(dimensions, "height") as? Int32, w > 0, h > 0 else { return 0 }
                return Int64(w) * Int64(h)
            }
            guard let largest = photos.max(by: { area($0) < area($1) }), area(largest) > 0,
                  let r = field(largest, "resource") else { return nil }
            resource = r
            video = false
        } else if named(full, "TelegramMediaFile"), let mime = field(full, "mimeType") as? String,
                  mime.hasPrefix("video/"), let r = field(full, "resource"),
                  named(r, "CloudDocumentMediaResource") {
            resource = r
            video = true
        } else { return nil }

        guard let dc = field(resource, "datacenterId") as? Int, dc > 0,
              let hash = field(resource, "accessHash") as? Int64,
              let reference = field(resource, "fileReference") as? Data else { return nil }
        let size = (field(resource, "size") as? Int64) ?? 0
        guard size >= 0 else { return nil }
        let location: Api.InputFileLocation
        let cacheId: String
        if video {
            guard let id = field(resource, "fileId") as? Int64 else { return nil }
            location = .inputDocumentFileLocation(.init(id: id, accessHash: hash,
                fileReference: Buffer(data: reference), thumbSize: ""))
            cacheId = "telegram-cloud-document-\(dc)-\(id)"
        } else {
            guard let id = field(resource, "photoId") as? Int64,
                  let spec = field(resource, "sizeSpec") as? String,
                  spec.utf8.count == 1, spec.utf8.allSatisfy({ (97...122).contains($0) }) else { return nil }
            location = .inputPhotoFileLocation(.init(id: id, accessHash: hash,
                fileReference: Buffer(data: reference), thumbSize: spec))
            cacheId = "telegram-cloud-photo-size-\(dc)-\(id)-\(spec)"
        }
        var cachePath: String?
        if let postbox = field(account, "postbox"), let mediaBox = field(postbox, "mediaBox"),
           let basePath = field(mediaBox, "basePath") as? String, !basePath.isEmpty {
            cachePath = (basePath as NSString).appendingPathComponent(cacheId)
        }
        let result = PaidMediaFile(context: context, master: master, dc: dc, size: size,
            video: video, cachePath: cachePath, location: location)
        if Thread.isMainThread { result.nativeItem = galleryItems.object(forKey: footer) }
        return result
    }

    private static func secretFile(footer: AnyObject, message: Any) -> PaidMediaFile? {
        guard let media = field(message, "media") as? [Any],
              let accountContext = field(footer, "context"), let account = field(accountContext, "account"),
              let postbox = field(account, "postbox"), let mediaBox = field(postbox, "mediaBox"),
              let basePath = field(mediaBox, "basePath") as? String, !basePath.isEmpty else { return nil }
        let resource: Any
        let video: Bool
        if let image = media.first(where: { named($0, "TelegramMediaImage") }),
           let representations = field(image, "representations") as? [Any],
           let full = representations.compactMap({ field($0, "resource") }).first(where: { named($0, "SecretFileMediaResource") }) {
            resource = full
            video = false
        } else if let file = media.first(where: { named($0, "TelegramMediaFile") }),
                  let mime = field(file, "mimeType") as? String, mime.hasPrefix("video/"),
                  let full = field(file, "resource"), named(full, "SecretFileMediaResource") {
            resource = full
            video = true
        } else { return nil }
        guard let id = field(resource, "fileId") as? Int64,
              let dc = field(resource, "datacenterId") as? Int, dc > 0,
              let size = field(resource, "decryptedSize") as? Int64, size > 0 else { return nil }
        let path = (basePath as NSString).appendingPathComponent("secret-file-\(id)-\(dc)")
        // Secret resources are decrypted by Telegram's own fetcher. Never send
        // their encrypted container through the cloud upload.getFile fallback.
        let result = PaidMediaFile(context: nil, master: 0, dc: dc, size: size,
                                   video: video, cachePath: path, location: nil, nativeOnly: true)
        if Thread.isMainThread { result.nativeItem = galleryItems.object(forKey: footer) }
        return result
    }

    @objc(downloadRequestAtOffset:)
    func downloadRequest(offset: Int64) -> Data? {
        guard let location = location, offset >= 0, offset % 524288 == 0, size == 0 || offset < size else { return nil }
        return Api.functions.upload.getFile(flags: 0, location: location, offset: offset, limit: 524288).1.makeValidData()
    }

    @objc(currentFooterNodeFromGalleryFooter:)
    static func currentFooterNode(container: AnyObject) -> AnyObject? {
        field(container, "currentFooterContentNode") as AnyObject?
    }

    @objc(footerNodeFromItem:)
    static func footerNode(item: AnyObject) -> AnyObject? {
        field(item, "footerContentNode") as AnyObject?
    }
}
