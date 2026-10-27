import Foundation

private struct CachedNumber32 { let rawValue: Int32 }
private struct CachedNumber64 { let rawValue: Int64 }
private struct CachedPeerId {
    let namespace: CachedNumber32
    let id: CachedNumber64
}
private struct CachedMessageId {
    let peerId: CachedPeerId
    let namespace: Int32
    let id: Int32
}
private struct CachedAccount { let basePath: String }
private struct CachedContext { let account: CachedAccount }
private struct CachedEntity: Encodable {
    let start: Int32
    let end: Int32
    let _rawValue: Int32
}
private final class TextEntitiesMessageAttribute {
    let entities: [CachedEntity]
    init(_ kind: Int32) { entities = [CachedEntity(start: 0, end: 8, _rawValue: kind)] }
}
private final class AdMessageAttribute {}
private final class EditedMessageAttribute {
    let date: Int32
    let isHidden = true // Hidden edit dates still order versions.
    init(_ date: Int32) { self.date = date }
}
private struct CachedMediaId { let namespace: Int32 = 0; let id: Int64 }
private struct CachedPhoto { let imageId: CachedMediaId }
private struct CachedFile { let fileId: CachedMediaId }
private struct CachedMessage {
    let id: CachedMessageId
    let text: String
    let attributes: [Any]
    let media: [Any]
    var flags = CachedNumber32(rawValue: 1 << 2)
}
private enum CachedContent {
    case message(message: CachedMessage, read: Bool, selection: Int, attributes: Int, location: Int?)
    case group(messages: [(CachedMessage, Bool, Int, Int, Int?)])
}
private class CachedItemBase {
    var content: CachedContent
    let context: CachedContext
    init(_ content: CachedContent, account: String) {
        self.content = content
        context = CachedContext(account: CachedAccount(basePath: "/container/accounts/\(account)"))
    }
}
private final class CachedItem: CachedItemBase, CustomStringConvertible {
    var message: CachedMessage { fatalError("Do not invoke Telegram's computed message") }
    var firstMessage: CachedMessage { fatalError("Do not invoke Telegram's computed firstMessage") }
    var description: String { fatalError("Do not describe or dump a ChatMessageItem") }
}
private class CachedNodeBase {
    var item: CachedItem?
    init(_ item: CachedItem?) { self.item = item }
}
private final class CachedNode: CachedNodeBase, CustomStringConvertible {
    var description: String { fatalError("Do not parse a node description") }
}

private func cachedMessage(_ id: Int32, text: String = "Cached original", edit: Int32? = nil,
                           peer: Int64 = 42, peerNamespace: Int32 = 0, namespace: Int32 = 0,
                           entities: Int32? = 6, media: [Any] = []) -> CachedMessage {
    var attributes = [Any]()
    if let entities = entities { attributes.append(TextEntitiesMessageAttribute(entities)) }
    if let edit = edit { attributes.append(EditedMessageAttribute(edit)) }
    return CachedMessage(id: CachedMessageId(peerId: CachedPeerId(namespace: CachedNumber32(rawValue: peerNamespace),
        id: CachedNumber64(rawValue: peer)), namespace: namespace, id: id), text: text, attributes: attributes, media: media)
}

private func cachedNode(_ message: CachedMessage, account: String = "account-1") -> CachedNode {
    CachedNode(CachedItem(.message(message: message, read: false, selection: 0, attributes: 0, location: nil), account: account))
}

func testRenderedMessages() {
    testEditHistoryButtonColors()
    flags("TGExtraAntiEdit")
    let node = cachedNode(cachedMessage(82000))
    check(TLParser.getMessageId(from: node.item as Any) == 82000, "Unwrap inherited optional item and named enum tuple")
    check(TLParser.getMessageIdFromNode(node) == 82000 && TLParser.getMessagePeerKeyFromNode(node) == 42 &&
          TLParser.getMessageNamespaceFromNode(node) == 0, "Extract all identity fields from the same stored MessageId")
    check(TLParser.messageState(from: node, observe: true)?["account"] as? String == testAccount, "Resolve the item's own account")
    let sponsored = cachedMessage(82012)
    let ad = CachedMessage(id: sponsored.id, text: sponsored.text, attributes: [AdMessageAttribute()], media: [])
    check(TLParser.hasAdMessageFromNode(cachedNode(ad)) && !TLParser.hasAdMessageFromNode(node), "Ad detection also reads stored attributes without computed message KVC")
    _ = strip(serialized(message(82000, text: "Network edit", edit: 2000)))
    check(history(forId: 82000, peer: 42) == ["Cached original", "Network edit"], "Cached original precedes the first observed network edit")
    for _ in 0..<3 { _ = TLParser.messageState(from: node, observe: true) }
    let older = cachedNode(cachedMessage(82000, text: "Old dated cache", edit: 1999))
    _ = TLParser.messageState(from: older, observe: true)
    let equal = cachedNode(cachedMessage(82000, text: "Stale within same second", edit: 2000))
    _ = TLParser.messageState(from: equal, observe: true)
    check(history(forId: 82000, peer: 42) == ["Cached original", "Network edit"], "Undated, older and equal-date cache snapshots never roll back a network edit")
    let current = cachedNode(cachedMessage(82000, text: "Network edit", edit: 2000))
    _ = TLParser.messageState(from: current, observe: true)
    _ = TLParser.messageState(from: cachedNode(cachedMessage(82000, text: "New cached edit", edit: 2001)), observe: true)
    _ = strip(serialized(message(82000, text: "New cached edit", edit: 2001)))
    check(history(forId: 82000, peer: 42) == ["Cached original", "Network edit", "New cached edit"], "Cache and wire observations of one edit do not duplicate it")

    _ = TLParser.messageState(from: cachedNode(cachedMessage(82001, text: "Same text")), observe: true)
    let italic = message(82001, text: "Same text", edit: 2000)
    messageData(italic).entities = [.messageEntityItalic(.init(offset: 0, length: 8))]
    _ = strip(serialized(italic))
    let details = TLParser.editRevisionDetails(forId: 82001, peer: 42, account: testAccount, namespace: 0)!
    check(details.count == 2 && details[1]["formatChanged"] as? Bool == true, "Cached entities compare with wire entities for formatting-only edits")
    _ = TLParser.messageState(from: cachedNode(cachedMessage(82001, text: "Same text", edit: 2000, entities: 7)), observe: true)
    check(history(forId: 82001, peer: 42)?.count == 2, "Rendering the wire formatting adds no duplicate")

    _ = TLParser.messageState(from: cachedNode(cachedMessage(82002, text: "", entities: nil,
        media: [CachedPhoto(imageId: CachedMediaId(id: 1))])), observe: true)
    let photoEdit = message(82002, text: "", media: .messageMediaPhoto(.init(flags: 1,
        photo: .photoEmpty(.init(id: 2)), ttlSeconds: nil, video: nil)), edit: 2000)
    messageData(photoEdit).entities = nil
    messageData(photoEdit).flags &= ~(1 << 7)
    _ = strip(serialized(photoEdit))
    let photoDetails = TLParser.editRevisionDetails(forId: 82002, peer: 42, account: testAccount, namespace: 0)!
    check(photoDetails.count == 2 && photoDetails[1]["mediaChanged"] as? Bool == true, "Empty cached captions retain attachment-only edits")
    _ = TLParser.messageState(from: cachedNode(cachedMessage(82003, text: "Caption")), observe: true)
    _ = strip(serialized(message(82003, text: "", edit: 2000)))
    check(history(forId: 82003, peer: 42) == ["Caption", ""], "A cleared caption is a real revision")
    _ = TLParser.messageState(from: cachedNode(cachedMessage(82004, text: "File", media: [CachedFile(fileId: CachedMediaId(id: 3))])), observe: true)
    _ = TLParser.messageState(from: cachedNode(cachedMessage(82004, text: "File", edit: 2000, media: [CachedFile(fileId: CachedMediaId(id: 4))])), observe: true)
    check(history(forId: 82004, peer: 42)?.count == 2, "Stored fileId detects cached document changes")

    struct UnknownAttachment { let metadata: Int }
    _ = TLParser.messageState(from: cachedNode(cachedMessage(82005, text: "Unknown", entities: 999,
        media: [UnknownAttachment(metadata: 1)])), observe: true)
    _ = strip(serialized(message(82005, text: "Unknown", edit: 2000)))
    check(history(forId: 82005, peer: 42) == nil, "Unknown entities/media are not treated as empty")

    let album = CachedNode(CachedItem(.group(messages: [
        (cachedMessage(82006, text: "Album first", peer: 77, peerNamespace: 2, namespace: 3), false, 0, 0, nil),
        (cachedMessage(82007, text: "Album second", peer: 77, peerNamespace: 2, namespace: 3), false, 0, 0, nil)
    ]), account: "account-2"))
    let albumState = TLParser.messageState(from: album, observe: true)!
    check(albumState["id"] as? NSNumber == 82006 && albumState["peer"] as? NSNumber == -1000000000077 &&
          albumState["namespace"] as? NSNumber == 3, "Albums keep the leading message's complete identity, not chatLocation")
    _ = TLParser.messageState(from: cachedNode(cachedMessage(82007, text: "Album revised", edit: 2000,
        peer: 77, peerNamespace: 2, namespace: 3), account: "account-2"), observe: true)
    check(history(forId: 82007, peer: -1000000000077, account: "account-2", namespace: 3) == ["Album second", "Album revised"], "Snapshot every album member")
    check(history(forId: 82007, peer: -1000000000077, namespace: 3) == nil &&
          history(forId: 82007, peer: -1000000000077, account: "account-2") == nil, "Cache recording isolates accounts and namespaces")
    check(TLParser.messageState(from: cachedNode(cachedMessage(82008), account: "account-invalid"), observe: true) == nil, "Do not guess an unresolved account")
    check(TLParser.getMessageIdFromNode(CachedNode(nil)) == nil, "An empty optional item has no identity")
    struct MisleadingItem: CustomStringConvertible {
        let messageId: Int32 = 82009
        var description: String { fatalError("No string fallback") }
    }
    check(TLParser.getMessageId(from: MisleadingItem()) == nil, "Unrecognized structures are skipped without string parsing")
    node.item = cachedNode(cachedMessage(82010, peer: 43, namespace: 5), account: "account-2").item
    let reused = TLParser.messageState(from: node, observe: false)!
    check(reused["id"] as? NSNumber == 82010 && reused["peer"] as? NSNumber == 43 &&
          reused["namespace"] as? NSNumber == 5 && reused["account"] as? String == "account-2", "Reused nodes resolve only their current stored item")
    _ = TLParser.messageState(from: cachedNode(cachedMessage(82000, text: "Other chat", peer: 43)), observe: true)
    _ = strip(serialized(message(82000, peer: .peerUser(.init(userId: 43)), text: "Other chat edit", edit: 2000)))
    check(history(forId: 82000, peer: 43) == ["Other chat", "Other chat edit"] &&
          history(forId: 82000, peer: 42)?.count == 3, "Matching cached message IDs in different chats remain independent")
    _ = strip(serialized(message(82000, text: "Unscoped response", edit: 9999)), account: nil)
    check(history(forId: 82000, peer: 42)?.count == 3, "Cache observations never set the network parser's account scope")
    let saved = defaultsForRenderedTests()
    check(saved["account-1:42:82000"]?["versions"] as? [String] == ["Cached original", "Network edit", "New cached edit"], "Persist merged cache/network history in the existing format")
    flags()
    _ = TLParser.messageState(from: cachedNode(cachedMessage(82011)), observe: true)
    flags("TGExtraAntiEdit")
    _ = strip(serialized(message(82011, text: "After enabling", edit: 2000)))
    check(history(forId: 82011, peer: 42) == nil, "Disabled Anti-Edit never records cache originals")
    print("PASS stored message reflection, cache/wire merging, albums, content revisions, reuse and account/namespace isolation")
}

private func testEditHistoryButtonColors() {
    struct VariableColor { let withWallpaper: String; let withoutWallpaper: String }
    struct Palette {
        let shareButtonFillColor: VariableColor
        let shareButtonForegroundColor: VariableColor
        let shareButtonStrokeColor: VariableColor
    }
    struct ChatTheme { let message: Palette }
    struct Theme { let chat: ChatTheme }
    enum Wallpaper { case color(Int32); case image }
    struct ThemeData { let theme: Theme; let wallpaper: Wallpaper }
    struct PresentationData { let theme: ThemeData }
    struct Item { let presentationData: PresentationData }
    class NodeBase { var item: Item? }
    final class Node: NodeBase {}
    let node = Node()
    func apply(_ name: String, wallpaper: Wallpaper) {
        let palette = Palette(
            shareButtonFillColor: VariableColor(withWallpaper: name + "-fill", withoutWallpaper: name + "-plain-fill"),
            shareButtonForegroundColor: VariableColor(withWallpaper: name + "-icon", withoutWallpaper: name + "-plain-icon"),
            shareButtonStrokeColor: VariableColor(withWallpaper: name + "-border", withoutWallpaper: name + "-plain-border"))
        node.item = Item(presentationData: PresentationData(theme: ThemeData(theme: Theme(chat: ChatTheme(message: palette)), wallpaper: wallpaper)))
    }
    check(TLParser.editHistoryButtonColorsFromNode(node) == nil, "Unbound nodes have no theme palette")
    apply("light", wallpaper: .image)
    check(TLParser.editHistoryButtonColorsFromNode(node) as? [String: String] ==
          ["fill": "light-fill", "foreground": "light-icon", "stroke": "light-border"],
          "Use the native side-button palette from the optional inherited item")
    apply("dark", wallpaper: .color(0x111111))
    check(TLParser.editHistoryButtonColorsFromNode(node)?["fill"] as? String == "dark-fill",
          "Theme changes and solid colored wallpapers use the current wallpaper palette")
    apply("light", wallpaper: .color(0xffffff))
    check(TLParser.editHistoryButtonColorsFromNode(node) as? [String: String] ==
          ["fill": "light-plain-fill", "foreground": "light-plain-icon", "stroke": "light-plain-border"],
          "Plain white wallpaper matches Telegram's withoutWallpaper special case")
    check(TLParser.editHistoryButtonColorsFromNode(NSObject()) == nil, "Unknown host layouts fall back without KVC")
}

private func defaultsForRenderedTests() -> [String: [String: Any]] {
    UserDefaults.standard.dictionary(forKey: "TGExtraEditHistoryByAccount") as! [String: [String: Any]]
}

func renderedHistoryRestoreFixture() -> [String: Any] {
    let entities = TLParser.serializeBoxed(Api.MessageEntity.messageEntityBold(.init(offset: 0, length: 8))) as Data
    return ["versions": ["Cached original", "Network edit"], "editDate": 2000,
            "contents": [["entities": entities, "mediaIdentity": Data()],
                         ["entities": entities, "mediaIdentity": Data(), "rich": Data()]]]
}

func testRestoredRenderedMessages() {
    var own = cachedMessage(40, text: "My current text", edit: 2002)
    own.flags = CachedNumber32(rawValue: 0)
    _ = TLParser.messageState(from: cachedNode(own), observe: true)
    check(history(forId: 40, peer: 42) == nil, "Rendering an own message removes its legacy history and badge")
    check(defaultsForRenderedTests()["account-1:42:40"] == nil, "Remove own legacy history from persistent storage")
    check(history(forId: 40, peer: 42, account: "account-2") == ["Other before", "Other after"], "Purging own history preserves other accounts")
    _ = TLParser.messageState(from: cachedNode(own), observe: true)
    own = cachedMessage(40, text: "My next edit", edit: 2003)
    own.flags = CachedNumber32(rawValue: 0)
    _ = TLParser.messageState(from: cachedNode(own), observe: true)
    check(history(forId: 40, peer: 42) == nil, "Rendering own edits cannot recreate history")
    check(history(forId: 82000, peer: 42) == ["Cached original", "Network edit"], "Reload cache-origin history in the existing storage format")
    _ = TLParser.messageState(from: cachedNode(cachedMessage(82000)), observe: true)
    _ = TLParser.messageState(from: cachedNode(cachedMessage(82000, text: "Stale cache", edit: 2000)), observe: true)
    check(history(forId: 82000, peer: 42) == ["Cached original", "Network edit"], "Restored watermark rejects stale rendered snapshots")
    _ = strip(serialized(message(82000, text: "Network edit", edit: 2000)))
    check(history(forId: 82000, peer: 42)?.count == 2, "Restored content deduplicates the same wire version")
    _ = strip(serialized(message(82000, text: "After restart", edit: 2001)))
    check(history(forId: 82000, peer: 42) == ["Cached original", "Network edit", "After restart"], "Recording continues after a restart")
}
