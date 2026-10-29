import Foundation
import CoreGraphics

// Read stored Swift fields, rather than calling non-Objective-C host methods or
// depending on their memory layout. Unknown layouts produce no export button.
@objc(TGExtraPaidMediaFile)
final class PaidMediaFile: NSObject {
    private static let galleryItems = NSMapTable<AnyObject, AnyObject>.weakToWeakObjects()
    @objc let context: NSObject
    @objc let masterDatacenterId: Int
    @objc let datacenterId: Int
    @objc let size: Int64
    @objc let video: Bool
    @objc let cachePath: String?
    private var nativeItem: AnyObject?
    private let location: Api.InputFileLocation

    private init(context: NSObject, master: Int, dc: Int, size: Int64, video: Bool,
                 cachePath: String?, location: Api.InputFileLocation) {
        self.context = context
        self.masterDatacenterId = master
        self.datacenterId = dc
        self.size = size
        self.video = video
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
        // Item state is assigned before footer presentation. Capture policy must
        // not depend on whether a network download descriptor can be constructed.
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
        guard Thread.isMainThread, video, let item = nativeItem,
              let footer = Self.field(item, "footerContentNode"),
              let current = Self.file(footer: footer as AnyObject), current.cachePath == cachePath,
              let controls = Self.field(item, "fetchControls"),
              let fetch = Self.field(controls, "fetch") as? () -> Void else { return false }
        // The footer button is a toggle: invoking it while Fetching would cancel
        // the download. Use the item's dedicated fetch closure instead.
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

    // A footer always tracks the current page, including albums and the local
    // synthetic message created by StarsTransactionScreen after purchase.
    @objc(fileFromFooterNode:)
    static func file(footer: AnyObject) -> PaidMediaFile? {
        guard let message = field(footer, "currentMessage"),
              let full = selectedMedia(message: message, subject: field(footer, "mediaSubject")),
              let accountContext = field(footer, "context"), let account = field(accountContext, "account"),
              let network = field(account, "network"), let context = field(network, "context") as? NSObject,
              let master = field(network, "datacenterId") as? Int, master > 0 else { return nil }

        let resource: Any
        let video: Bool
        if named(full, "TelegramMediaImage"), let representations = field(full, "representations") as? [Any] {
            // Keep the largest original representation; never export a preview
            // or the capture-protected rendered image from the screen.
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

    @objc(downloadRequestAtOffset:)
    func downloadRequest(offset: Int64) -> Data? {
        guard offset >= 0, offset % 524288 == 0, size == 0 || offset < size else { return nil }
        return Api.functions.upload.getFile(flags: 0, location: location, offset: offset, limit: 524288).1.makeValidData()
    }

    @objc(contentNodeFromFooter:)
    static func contentNode(footer: AnyObject) -> AnyObject? {
        field(footer, "contentNode") as AnyObject?
    }

    @objc(footerNodeFromItem:)
    static func footerNode(item: AnyObject) -> AnyObject? {
        field(item, "footerContentNode") as AnyObject?
    }

    @objc(bottomInsetFromFooter:)
    static func bottomInset(footer: AnyObject) -> Double {
        guard let layout = field(footer, "validLayout"), let inset = field(layout, ".4") as? CGFloat else { return 0 }
        return Double(inset)
    }
}
