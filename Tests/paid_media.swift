import Foundation
import CoreGraphics

// Stored-property shapes from Telegram-iOS fb0e62ba8a. These deliberately have
// no host methods or Objective-C getters: extraction must use Swift reflection.
private enum PaidMediaMocks {
    struct CloudPhotoSizeMediaResource {
        let datacenterId = 4
        let photoId: Int64
        let accessHash: Int64 = 99
        let sizeSpec: String
        let size: Int64? = 524291
        let fileReference: Data? = Data([1, 2, 3])
    }
    struct CloudDocumentMediaResource {
        let datacenterId = 5
        let fileId: Int64 = 567
        let accessHash: Int64 = 100
        let size: Int64? = nil
        let fileReference: Data? = Data([4, 5])
    }
    struct Dimensions { let width: Int32; let height: Int32 }
    struct Representation { let dimensions: Dimensions; let resource: Any }
    struct TelegramMediaImage { let representations: [Representation] }
    struct TelegramMediaFile { let mimeType: String; let resource: Any }
    enum ExtendedMedia { case preview(dimensions: Int?); case full(media: Any) }
    struct TelegramMediaPaidContent { let extendedMedia: [ExtendedMedia] }
    struct Message { let media: [Any] }
    enum Subject { case paidMediaIndex(Int); case other(Int) }
    struct MediaBox { let basePath: String }
    struct Postbox { let mediaBox: MediaBox }
    struct Network { let context = NSObject(); let datacenterId = 2 }
    struct Account { let network = Network(); let postbox: Postbox }
    struct Context { let account: Account }
    class Footer: NSObject {
        let context: Context
        var currentMessage: Message?
        var mediaSubject: Subject?
        let contentNode = NSObject()
        let validLayout: (CGSize, Int, CGFloat, CGFloat, CGFloat, CGFloat)? = (.zero, 0, 0, 0, 34, 0)
        init(path: String) {
            context = Context(account: Account(postbox: Postbox(mediaBox: MediaBox(basePath: path))))
        }
    }
    // Reading a Swift superclass is required for clients that subclass nodes.
    final class DerivedFooter: Footer {}
    final class Item: NSObject {
        let footerContentNode: Footer
        var message: Message?
        var mediaSubject: Subject?
        var item: VideoItem?
        var fetchControls: FetchControls?
        var fetchStatus: FetchStatus?
        init(footer: Footer) { self.footerContentNode = footer }
    }
    enum ContentInfo { case message(Message, Subject?); case webPage }
    struct VideoItem { let contentInfo: ContentInfo? }
    struct FetchControls { let fetch: () -> Void; let cancel: () -> Void }
    enum FetchStatus { case Remote; case Fetching(isActive: Bool, progress: Float) }
}

func testPaidMedia() {
    typealias M = PaidMediaMocks
    let footer = M.DerivedFooter(path: "/cache/account-17/postbox/media")
    func photo(_ id: Int64) -> M.TelegramMediaImage {
        M.TelegramMediaImage(representations: [
            .init(dimensions: .init(width: 3000, height: 2000),
                  resource: M.CloudPhotoSizeMediaResource(photoId: id, sizeSpec: "y")),
            .init(dimensions: .init(width: 100, height: 100),
                  resource: M.CloudPhotoSizeMediaResource(photoId: id, sizeSpec: "s"))
        ])
    }
    footer.currentMessage = .init(media: [M.TelegramMediaPaidContent(extendedMedia: [
        .full(media: photo(123)), .full(media: photo(456)), .preview(dimensions: nil),
        .full(media: M.TelegramMediaFile(mimeType: "video/mp4", resource: M.CloudDocumentMediaResource()))
    ])])
    guard let first = PaidMediaFile.file(footer: footer) else { fatalError("Paid photo not found") }
    check(first.cachePath == "/cache/account-17/postbox/media/telegram-cloud-photo-size-4-123-y",
          "Paid photo selects largest original and owning account's complete cache")
    check(!first.video && first.size == 524291 && first.datacenterId == 4 && first.masterDatacenterId == 2,
          "Paid file keeps its source DC, master DC and byte size")
    check(first.context === footer.context.account.network.context, "Paid download uses the footer account's MTContext")
    check(PaidMediaFile.contentNode(footer: footer) === footer.contentNode, "Save control follows the native controls container")
    check(PaidMediaFile.bottomInset(footer: footer) == 34, "Save control respects the footer bottom inset")
    check(PaidMediaFile.footerNode(item: M.Item(footer: footer)) === footer,
          "Capture policy resolves the gallery item's own footer")
    let earlyImage = M.Item(footer: M.Footer(path: ""))
    earlyImage.message = footer.currentMessage
    check(PaidMediaFile.isUnlockedPaidItem(earlyImage),
          "Capture policy works from item state before its footer is populated")

    guard let request = first.downloadRequest(offset: 0) else { fatalError("Paid file request missing") }
    let reader = BufferReader(Buffer(data: request))
    check(reader.readInt32() == -1101843010 && reader.readInt32() == 0,
          "Paid download uses upload.getFile without CDN redirects")
    let location = Api.parse(reader, signature: reader.readInt32()!) as? Api.InputFileLocation
    guard case let .inputPhotoFileLocation(data)? = location else { fatalError("Wrong photo location") }
    check(data.id == 123 && data.accessHash == 99 && data.thumbSize == "y" && data.fileReference.makeData() == Data([1, 2, 3]),
          "Paid download retains the authorized resource reference")
    check(reader.readInt64() == 0 && reader.readInt32() == 524288, "Paid download uses aligned bounded chunks")
    check(first.downloadRequest(offset: 524288) != nil && first.downloadRequest(offset: 1048576) == nil &&
          first.downloadRequest(offset: -1) == nil && first.downloadRequest(offset: 1) == nil,
          "Paid download rejects invalid offsets and reads past the known end")

    footer.mediaSubject = .paidMediaIndex(1)
    check(PaidMediaFile.file(footer: footer)?.cachePath?.hasSuffix("4-456-y") == true,
          "Swiping an album exports the selected page")
    footer.mediaSubject = .paidMediaIndex(2)
    check(PaidMediaFile.file(footer: footer) == nil, "Locked paid previews cannot be exported")
    footer.mediaSubject = .paidMediaIndex(3)
    guard let video = PaidMediaFile.file(footer: footer) else { fatalError("Paid video not found") }
    check(video.video && video.size == 0 && video.cachePath?.hasSuffix("telegram-cloud-document-5-567") == true,
          "Paid video uses the original document, supporting unknown lengths")
    let videoItem = M.Item(footer: footer)
    videoItem.item = .init(contentInfo: .message(footer.currentMessage!, footer.mediaSubject))
    check(PaidMediaFile.isUnlockedPaidItem(videoItem), "Video capture policy reads its contentInfo message")
    videoItem.item = .init(contentInfo: .webPage)
    check(!PaidMediaFile.isUnlockedPaidItem(videoItem), "A reused non-message video ignores stale paid footer state")
    videoItem.item = .init(contentInfo: .message(footer.currentMessage!, footer.mediaSubject))
    var nativeFetches = 0
    videoItem.fetchControls = .init(fetch: { nativeFetches += 1 }, cancel: { fatalError("Saving must never cancel a native fetch") })
    PaidMediaFile.bindGalleryItem(videoItem)
    let nativeVideo = PaidMediaFile.file(footer: footer)!
    check(nativeVideo.beginNativeDownload() && nativeFetches == 1, "Video saving starts the host's native full-file fetch")
    videoItem.fetchStatus = .Fetching(isActive: true, progress: 0.5)
    check(nativeVideo.beginNativeDownload() && nativeFetches == 1 && nativeVideo.nativeDownloadProgress == 0.5,
          "Saving an already downloading video preserves the fetch and reports native progress")
    footer.mediaSubject = .paidMediaIndex(0)
    check(!nativeVideo.beginNativeDownload(), "A delayed save cannot start downloading another album page")
    footer.mediaSubject = .paidMediaIndex(3)
    guard let bytes = video.downloadRequest(offset: 524288) else { fatalError("Unknown length request missing") }
    let videoReader = BufferReader(Buffer(data: bytes))
    _ = videoReader.readInt32(); _ = videoReader.readInt32()
    let videoLocation = Api.parse(videoReader, signature: videoReader.readInt32()!) as? Api.InputFileLocation
    guard case let .inputDocumentFileLocation(document)? = videoLocation else { fatalError("Wrong video location") }
    check(document.id == 567 && document.thumbSize.isEmpty, "Paid video downloads the full file rather than its thumbnail")
    footer.mediaSubject = .paidMediaIndex(-1)
    check(PaidMediaFile.file(footer: footer) == nil, "Invalid paid album index fails closed")
    footer.mediaSubject = .other(0)
    check(PaidMediaFile.file(footer: footer) == nil, "Unknown gallery subjects fail closed")
    footer.mediaSubject = nil
    footer.currentMessage = .init(media: [photo(123)])
    check(PaidMediaFile.file(footer: footer) == nil, "Ordinary gallery media keeps its native save action")
    footer.currentMessage = .init(media: [M.TelegramMediaPaidContent(extendedMedia: [
        .full(media: M.TelegramMediaFile(mimeType: "audio/ogg", resource: M.CloudDocumentMediaResource()))
    ])])
    check(PaidMediaFile.file(footer: footer) == nil, "Unsupported media cannot be mislabeled as video")
    check(PaidMediaFile.file(footer: NSObject()) == nil, "Unknown host layouts fail closed")
}
