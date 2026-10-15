import Foundation
import TestSupport
import zlib

let defaults = TGExtraUseTestDefaults()!
precondition(UserDefaults.standard === defaults, "Tests must use in-memory defaults")
if CommandLine.arguments.contains("--restore") {
    var saved = ["42:40": ["Before", "After"], "42:41": ["", "Caption", ""]]
    for id in 10_000...12_100 { saved["42:\(id)"] = ["Unedited"] }
    defaults.set(saved, forKey: "TGExtraEditHistoryByPeer")
    defaults.set(["10": [NSNumber(value: 0)]], forKey: "TGExtraDeletedMsgIds")
    defaults.set(["20": [NSNumber(value: 0)]], forKey: "TGExtraAutoDeleteMsgIds")
    defaults.set(true, forKey: "TGExtraAntiAutoDelete")
    defaults.set(999, forKey: "TGExtraLastKnownUserId")
    TLParser.loadPersistedIds()
    precondition(TLParser.editHistory(forId: 40, peer: 42) == ["Before", "After"])
    precondition(TLParser.editHistory(forId: 41, peer: 42) == ["", "Caption", ""])
    precondition(TLParser.isDeleted(10, peer: 42))
    let deletion = Api.Update.updateDeleteMessages(.init(messages: [20], pts: 5, ptsCount: 1))
    precondition(TLParser.stripAntiSelfDestruct(TLParser.serializeBoxed(deletion)) != nil)
    print("PASS persisted edit history, deletion markers and timer classification")
    exit(0)
}
TGExtraTestHandlersAndMigration()
defaults.set(999, forKey: "TGExtraLastKnownUserId")

func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    precondition(condition(), message)
}
func flags(_ enabled: String...) {
    for key in ["TGExtraAntiRevoke", "TGExtraAntiAutoDelete", "TGExtraAntiSelfDestruct", "TGExtraAntiEdit", "disableForwardRestriction", "TGExtraVideoToVoice", "TGExtraIgnorePrivateChatCopyProtection"] {
        defaults.set(enabled.contains(key), forKey: key)
    }
}
func serialized(_ value: Any) -> NSData { TLParser.serializeBoxed(value) }
func parsed<T>(_ bytes: NSData, as type: T.Type) -> T {
    let reader = BufferReader(Buffer(nsData: bytes))
    let signature = reader.readInt32()!
    let value = Api.parse(reader, signature: signature) as! T
    check(reader.offset == UInt(bytes.length), "Parse consumed the whole response")
    return value
}
func message(_ id: Int32, peer: Api.Peer = .peerUser(.init(userId: 42)), text: String = "Original 😀", ttl: Int32? = nil, media: Api.MessageMedia? = nil, edit: Int32? = nil) -> Api.Message {
    var bits: Int32 = 1 << 7
    if ttl != nil { bits |= 1 << 25 }
    if media != nil { bits |= 1 << 9 }
    if edit != nil { bits |= 1 << 15 }
    return .message(.init(flags: bits, flags2: (1 << 6) | (1 << 10) | (1 << 11), id: id,
        fromId: nil, fromBoostsApplied: nil, fromRank: nil, peerId: peer, savedPeerId: nil,
        fwdFrom: nil, viaBotId: nil, viaBusinessBotId: nil, guestchatViaFrom: nil, replyTo: nil,
        date: 1234, message: text, media: media, replyMarkup: nil,
        entities: [.messageEntityBold(.init(offset: 0, length: 8))], views: nil, forwards: nil,
        replies: nil, editDate: edit, postAuthor: nil, groupedId: nil, reactions: nil,
        restrictionReason: nil, ttlPeriod: ttl, quickReplyShortcutId: nil, effect: nil, factcheck: nil,
        reportDeliveryUntilDate: nil, paidMessageStars: 456, suggestedPost: nil,
        scheduleRepeatPeriod: 3600, summaryFromLanguage: "ru", richMessage: nil))
}
func messageData(_ message: Api.Message) -> Api.Message.Cons_message {
    guard case let .message(data) = message else { fatalError("Expected message") }
    return data
}
func deletion(_ ids: [Int32], channel: Int64? = nil) -> Api.Update {
    if let channel { return .updateDeleteChannelMessages(.init(channelId: channel, messages: ids, pts: 52, ptsCount: 3)) }
    return .updateDeleteMessages(.init(messages: ids, pts: 52, ptsCount: 3))
}
func deletionIds(_ update: Api.Update) -> [Int32] {
    switch update {
    case let .updateDeleteMessages(data):
        check(data.pts == 52 && data.ptsCount == 3, "Keep synchronization counters")
        return data.messages
    case let .updateDeleteChannelMessages(data):
        check(data.pts == 52 && data.ptsCount == 3, "Keep channel synchronization counters")
        return data.messages
    default: fatalError("Expected deletion")
    }
}
func patch(_ value: Any) -> NSData? { TLParser.stripAntiSelfDestruct(serialized(value)) }

flags()
let privateUser = Api.UserFull.userFull(.init(
    flags: 0,
    flags2: (1 << 23) | (1 << 24) | (1 << 26),
    id: 42,
    about: nil,
    settings: .peerSettings(.init(flags: 0, geoDistance: nil, requestChatTitle: nil, requestChatDate: nil, businessBotId: nil, businessBotManageUrl: nil, chargePaidMessageStars: nil, registrationMonth: nil, phoneCountry: nil, nameChangeDate: nil, photoChangeDate: nil)),
    personalPhoto: nil,
    profilePhoto: nil,
    fallbackPhoto: nil,
    notifySettings: .peerNotifySettings(.init(flags: 0, showPreviews: nil, silent: nil, muteUntil: nil, iosSound: nil, androidSound: nil, otherSound: nil, storiesMuted: nil, storiesHideSender: nil, storiesIosSound: nil, storiesAndroidSound: nil, storiesOtherSound: nil)),
    botInfo: nil,
    pinnedMsgId: nil,
    commonChatsCount: 7,
    folderId: nil,
    ttlPeriod: nil,
    theme: nil,
    privateForwardName: nil,
    botGroupAdminRights: nil,
    botBroadcastAdminRights: nil,
    wallpaper: nil,
    stories: nil,
    businessWorkHours: nil,
    businessLocation: nil,
    businessGreetingMessage: nil,
    businessAwayMessage: nil,
    businessIntro: nil,
    birthday: nil,
    personalChannelId: nil,
    personalChannelMessage: nil,
    stargiftsCount: nil,
    starrefProgram: nil,
    botVerification: nil,
    sendPaidMessagesStars: nil,
    disallowedGifts: nil,
    starsRating: nil,
    starsMyPendingRating: nil,
    starsMyPendingRatingDate: nil,
    mainTab: nil,
    savedMusic: nil,
    note: nil,
    botManagerId: nil))
let protectedGroup = Api.Chat.chat(.init(flags: 1 << 25, id: 77, title: "Protected group",
    photo: .chatPhotoEmpty, participantsCount: 2, date: 1234, version: 1,
    migratedTo: nil, adminRights: nil, defaultBannedRights: nil))
let privateResponse = Api.users.UserFull.userFull(.init(fullUser: privateUser, chats: [protectedGroup], users: []))
let privateBytes = serialized(privateResponse)
check(TLParser.handleResponse(privateBytes, functionID: -1240508136) == nil, "Private copy bypass defaults to off")
flags("TGExtraIgnorePrivateChatCopyProtection")
let privatePatched = TLParser.handleResponse(privateBytes, functionID: -1240508136)!
let privateDecoded = parsed(privatePatched, as: Api.users.UserFull.self)
guard case let .userFull(fullResponse) = privateDecoded,
      case let .userFull(fullUser) = fullResponse.fullUser else { fatalError("Expected full user") }
check(fullUser.flags2 == 1 << 26, "Clear only the two private-chat copy flags")
check(fullUser.id == 42 && fullUser.commonChatsCount == 7, "Keep private profile fields intact")
check((privatePatched as Data).prefix(12) == (privateBytes as Data).prefix(12) &&
      (privatePatched as Data).dropFirst(16) == (privateBytes as Data).dropFirst(16), "Only flags2 bytes change; nested chats and users stay untouched")
let privatePacked = Buffer()
privatePacked.appendInt32(0x3072cfa1)
serializeBytes(Buffer(data: gzip(privateBytes as Data)), buffer: privatePacked, boxed: false)
check(TLParser.handleResponse(privatePacked.makeData() as NSData, functionID: -1240508136) == privatePatched, "Handle gzipped private-chat settings")
check(TLParser.handleResponse(privatePatched, functionID: -1240508136) == nil, "An already-cleared private profile is unchanged")
let directPrivate = parsed(patch(privateUser)!, as: Api.UserFull.self)
guard case let .userFull(directUser) = directPrivate else { fatalError("Expected direct user") }
check(directUser.flags2 == 1 << 26, "Handle a direct userFull constructor")
let unrelated = serialized(message(900, peer: .peerChannel(.init(channelId: 900))))
check(TLParser.stripAntiSelfDestruct(unrelated) == nil, "Private bypass does not rewrite channel messages")
for length in 0..<privateBytes.length {
    check(TLParser.stripAntiSelfDestruct((privateBytes as Data).prefix(length) as NSData) == nil, "Truncated full-user replies pass through")
}
flags()
check(TLParser.handleResponse(privateBytes, functionID: -1240508136) == nil, "Turning the private option off restores the original response")
print("PASS independent private-chat copy protection bypass")

flags("TGExtraAntiRevoke")
// The host can decode a newer User/Chat constructor even when our bundled
// schema cannot. Deletions in the preceding update vector must still be blocked.
func updatesWithOpaquePeer(_ updates: [Api.Update], combined: Bool = false, opaqueChat: Bool = false) -> NSData {
    let buffer = Buffer()
    buffer.appendInt32(combined ? 1918567619 : 1957577280)
    buffer.appendInt32(481674261)
    buffer.appendInt32(Int32(updates.count))
    for update in updates { update.serialize(buffer, true) }
    buffer.appendInt32(481674261)
    buffer.appendInt32(opaqueChat ? 0 : 1)
    if opaqueChat {
        buffer.appendInt32(481674261)
        buffer.appendInt32(1)
    }
    buffer.appendInt32(1234567) // opaque peer constructor
    buffer.appendInt32(0)
    if !opaqueChat {
        buffer.appendInt32(481674261)
        buffer.appendInt32(0)
    }
    buffer.appendInt32(1234)
    if combined { buffer.appendInt32(7) }
    buffer.appendInt32(8)
    return buffer.makeData() as NSData
}
for combined in [false, true] {
  for opaqueChat in [false, true] {
    let bytes = updatesWithOpaquePeer([
        deletion([101, 102]),
        .updateReadHistoryOutbox(.init(peer: .peerUser(.init(userId: 42)), maxId: 9, pts: 51, ptsCount: 1))
    ], combined: combined, opaqueChat: opaqueChat)
    let patched = TLParser.stripAntiSelfDestruct(bytes)
    check(patched != nil, "Block deletions even when the peer vector cannot be decoded")
    let reader = BufferReader(Buffer(nsData: patched!))
    reader.skip(12)
    check(deletionIds(Api.parse(reader, signature: reader.readInt32()!) as! Api.Update) == [0, 0], "Neutralize the deletion in the update vector")
    check((patched! as Data).prefix(24) == (bytes as Data).prefix(24) &&
          (patched! as Data).dropFirst(32) == (bytes as Data).dropFirst(32), "Only deletion IDs change; other updates and opaque peers stay intact")
  }
}
let opaqueChannel = updatesWithOpaquePeer([deletion([103], channel: 77)])
let opaqueChannelReader = BufferReader(Buffer(nsData: TLParser.stripAntiSelfDestruct(opaqueChannel)!))
opaqueChannelReader.skip(12)
check(deletionIds(Api.parse(opaqueChannelReader, signature: opaqueChannelReader.readInt32()!) as! Api.Update) == [0], "Protect channel deletions with an opaque peer vector")
check(TLParser.isDeleted(103, peer: -1_000_000_000_077) && !TLParser.isDeleted(103, peer: 42), "Fallback deletion markers retain their channel scope")
let revoked = parsed(patch(deletion([10, 11]))!, as: Api.Update.self)
check(deletionIds(revoked) == [0, 0], "Retain deleted messages")
check(TLParser.isDeleted(10, peer: 42), "Deletion marker is scoped to private chats")
check(!TLParser.isDeleted(10, peer: -1_000_000_000_077), "Private deletion never marks a channel")
let channelDeleted = parsed(patch(deletion([10], channel: 77))!, as: Api.Update.self)
check(deletionIds(channelDeleted) == [0], "Retain channel deletion")
check(!TLParser.isDeleted(10, peer: -1_000_000_000_078), "Repeated channel message IDs stay independent")
flags()
check(patch(deletion([12])) == nil, "Disabled anti-revoke passes through")
check(TLParser.stripAntiSelfDestruct(updatesWithOpaquePeer([deletion([104])])) == nil, "Disabled anti-revoke leaves opaque updates untouched")
check(!TLParser.isDeleted(104, peer: 42), "Disabled fallback does not record deletions")
flags("TGExtraAntiRevoke")
let brokenVector = NSMutableData(data: updatesWithOpaquePeer([
    deletion([106]), deletion([107])
]) as Data)
var unknownUpdate: Int32 = 1234567
brokenVector.replaceBytes(in: NSRange(location: 12 + serialized(deletion([106])).length, length: 4), withBytes: &unknownUpdate)
check(TLParser.stripAntiSelfDestruct(brokenVector) == nil, "An unknown update cannot be skipped without its length")
check(!TLParser.isDeleted(106, peer: 42), "Do not record partial update vectors")
let ordinaryBatch = serialized(Api.Updates.updates(.init(updates: [deletion([108])], users: [], chats: [], date: 1234, seq: 8)))
for length in 0..<ordinaryBatch.length {
    check(TLParser.stripAntiSelfDestruct((ordinaryBatch as Data).prefix(length) as NSData) == nil, "Incomplete update vectors and framing pass through")
}
var trailingGarbage = ordinaryBatch as Data
trailingGarbage.append(contentsOf: [0, 0, 0, 0])
check(TLParser.stripAntiSelfDestruct(trailingGarbage as NSData) == nil, "Updates with trailing garbage pass through")

flags("TGExtraAntiRevoke", "TGExtraAntiEdit", "TGExtraAntiAutoDelete")
let knownPeerUpdates: [Api.Update] = [
    .updateNewMessage(.init(message: message(120, ttl: 86400), pts: 50, ptsCount: 1)),
    deletion([121])
]
for combined in [false, true] {
    let users: [Api.User] = [.userEmpty(.init(id: 42))]
    let chats: [Api.Chat] = [.chatEmpty(.init(id: 77))]
    let batch: Api.Updates = combined
        ? .updatesCombined(.init(updates: knownPeerUpdates, users: users, chats: chats, date: 1234, seqStart: 7, seq: 8))
        : .updates(.init(updates: knownPeerUpdates, users: users, chats: chats, date: 1234, seq: 8))
    let bytes = serialized(batch) as Data
    for length in 0..<bytes.count {
        check(TLParser.stripAntiSelfDestruct(bytes.prefix(length) as NSData) == nil, "Truncated known peers and synchronization fields pass through")
    }
    check(!TLParser.isDeleted(121, peer: 42), "Rejected packets do not record deletion markers")
    let usersOffset = 12 + knownPeerUpdates.reduce(0) { $0 + serialized($1).length }
    for (offset, value) in [(usersOffset + 4, Int32(-1)), (usersOffset + 24, Int32(-1)), (usersOffset + 8, Int32(693512293))] {
        var invalid = bytes
        var word = value.littleEndian
        withUnsafeBytes(of: &word) { invalid.replaceSubrange(offset..<offset + 4, with: $0) }
        check(TLParser.stripAntiSelfDestruct(invalid as NSData) == nil, "Invalid peer vector framing does not enable the fallback")
        check(!TLParser.isDeleted(121, peer: 42), "Invalid peer vectors do not record deletion markers")
    }
}
_ = patch(Api.Update.updateEditMessage(.init(message: message(120, text: "Valid edit", edit: 1235), pts: 51, ptsCount: 1)))
check(TLParser.editHistory(forId: 120, peer: 42) == nil, "Rejected originals never enter edit history")
flags("TGExtraAntiAutoDelete")
check(patch(deletion([120])) == nil, "Rejected packets do not classify timed messages")

flags("TGExtraAntiAutoDelete")
let autoDeleted = messageData(parsed(patch(message(20, ttl: 86400))!, as: Api.Message.self))
check(autoDeleted.ttlPeriod == nil, "Remove local chat auto-delete timer")
check(autoDeleted.message == "Original 😀", "Chat auto-delete does not add a disappearing-media label")
check(autoDeleted.paidMessageStars == 456 && autoDeleted.scheduleRepeatPeriod == 3600 && autoDeleted.summaryFromLanguage == "ru", "Preserve API 13.0 optional fields")
check(deletionIds(parsed(patch(deletion([20, 21]))!, as: Api.Update.self)) == [0, 21], "Protect only known auto-delete messages")
let channel = Api.Peer.peerChannel(.init(channelId: 88))
_ = patch(message(22, peer: channel, ttl: 60))
check(patch(deletion([22], channel: 89)) == nil, "TTL IDs are scoped to channels")
check(deletionIds(parsed(patch(deletion([22], channel: 88))!, as: Api.Update.self)) == [0], "Protect auto-delete in the matching channel")
let opaqueTimer = updatesWithOpaquePeer([.updateNewMessage(.init(message: message(109, ttl: 86400), pts: 50, ptsCount: 1))])
let timerReader = BufferReader(Buffer(nsData: TLParser.stripAntiSelfDestruct(opaqueTimer)!))
timerReader.skip(12)
guard case let .updateNewMessage(timerUpdate) = Api.parse(timerReader, signature: timerReader.readInt32()!) as! Api.Update else { fatalError("Expected new message") }
check(messageData(timerUpdate.message).ttlPeriod == nil, "Strip chat timers despite unknown peers")
check(deletionIds(parsed(patch(deletion([109, 110]))!, as: Api.Update.self)) == [0, 110], "Fallback timer classification protects only timed messages")

flags("TGExtraAntiSelfDestruct")
let photo = Api.MessageMedia.messageMediaPhoto(.init(flags: (1 << 0) | (1 << 2) | (1 << 3), photo: .photoEmpty(.init(id: 99)), ttlSeconds: 5, video: nil))
let oneTime = messageData(parsed(patch(message(30, media: photo))!, as: Api.Message.self))
guard case let .messageMediaPhoto(photoData) = oneTime.media! else { fatalError("Expected photo") }
check(photoData.ttlSeconds == nil, "Clear one-time photo timer")
check(photoData.flags & (1 << 3) != 0, "Keep the spoiler flag")
check(deletionIds(parsed(patch(deletion([30, 31]))!, as: Api.Update.self)) == [0, 31], "Only known disappearing media is protected")
check(patch(message(32, ttl: 86400)) == nil, "One-time media setting does not disable chat auto-delete")
defaults.set(true, forKey: "TGExtraHideDisappearingLabel")
let hiddenLabel = messageData(parsed(patch(message(33, media: photo))!, as: Api.Message.self))
check(hiddenLabel.message == "Original 😀", "Hide disappearing label")
defaults.set(false, forKey: "TGExtraHideDisappearingLabel")
let opaqueMedia = updatesWithOpaquePeer([.updateNewMessage(.init(message: message(111, media: photo), pts: 50, ptsCount: 1))])
let mediaReader = BufferReader(Buffer(nsData: TLParser.stripAntiSelfDestruct(opaqueMedia)!))
mediaReader.skip(12)
guard case let .updateNewMessage(mediaUpdate) = Api.parse(mediaReader, signature: mediaReader.readInt32()!) as! Api.Update,
      case let .messageMediaPhoto(mediaPhoto) = messageData(mediaUpdate.message).media! else { fatalError("Expected disappearing photo") }
check(mediaPhoto.ttlSeconds == nil, "Strip disappearing media timers despite unknown peers")
check(deletionIds(parsed(patch(deletion([111, 112]))!, as: Api.Update.self)) == [0, 112], "Fallback disappearing classification remains selective")

flags("disableForwardRestriction")
let protectedMessage = message(113)
messageData(protectedMessage).flags |= 1 << 26
let opaqueProtected = updatesWithOpaquePeer([.updateNewMessage(.init(message: protectedMessage, pts: 50, ptsCount: 1))])
let protectedBytes = TLParser.stripAntiSelfDestruct(opaqueProtected)!
let protectedReader = BufferReader(Buffer(nsData: protectedBytes))
protectedReader.skip(20) // Updates header, updateNewMessage and Message constructors
check(protectedReader.readInt32()! & (1 << 26) == 0, "Serialize the generated noforwards change despite unknown peers")
flags("TGExtraAntiEdit")
check(TLParser.stripAntiSelfDestruct(opaqueProtected) == nil, "Recording alone keeps protected wire flags unchanged")

flags("TGExtraAntiEdit")
let original = message(40)
_ = patch(Api.Update.updateNewMessage(.init(message: original, pts: 50, ptsCount: 1)))
let edited = message(40, text: "New text", edit: 1235)
check(patch(Api.Update.updateEditMessage(.init(message: edited, pts: 51, ptsCount: 1))) == nil, "Keep latest edited text in the chat")
check(TLParser.editHistory(forId: 40, peer: 42) == ["Original 😀", "New text"], "Keep original and revised text")
check(TLParser.editHistory(forId: 40, peer: 43) == nil, "Never mix edit histories across peers")
check(defaults.dictionary(forKey: "TGExtraEditHistoryByPeer") != nil, "Persist edit history immediately")
let opaqueOriginal = updatesWithOpaquePeer([.updateNewMessage(.init(message: message(105), pts: 50, ptsCount: 1))])
check(TLParser.stripAntiSelfDestruct(opaqueOriginal) == nil, "Recording an original preserves opaque packet bytes")
let opaqueEdit = updatesWithOpaquePeer([.updateEditMessage(.init(message: message(105, text: "Edited in opaque batch", edit: 1235), pts: 51, ptsCount: 1))], combined: true)
check(TLParser.stripAntiSelfDestruct(opaqueEdit) == nil, "Recording an edit preserves opaque packet bytes")
check(TLParser.editHistory(forId: 105, peer: 42) == ["Original 😀", "Edited in opaque batch"], "Track original and edit even when peer data is unknown")

flags("TGExtraAntiRevoke", "TGExtraAntiEdit")
let opaqueMixed = updatesWithOpaquePeer([
    .updateEditMessage(.init(message: message(105, text: "Second edit", edit: 1236), pts: 52, ptsCount: 1)),
    deletion([105])
])
check(TLParser.stripAntiSelfDestruct(opaqueMixed) != nil, "Protect deletion and record editing in the same opaque packet")
check(TLParser.editHistory(forId: 105, peer: 42) == ["Original 😀", "Edited in opaque batch", "Second edit"], "Keep every text revision when deletion protection is also enabled")
check(TLParser.isDeleted(105, peer: 42), "Mark the deleted message from a mixed packet")
for (channelId, peer) in [(Int64(77), Int64(-1_000_000_000_077)), (78, -1_000_000_000_078)] {
    let original = message(114, peer: .peerChannel(.init(channelId: channelId)), text: "Channel \(channelId)")
    _ = TLParser.stripAntiSelfDestruct(updatesWithOpaquePeer([.updateNewChannelMessage(.init(message: original, pts: 50, ptsCount: 1))]))
    let edited = message(114, peer: .peerChannel(.init(channelId: channelId)), text: "Edited channel \(channelId)", edit: 1235)
    _ = TLParser.stripAntiSelfDestruct(updatesWithOpaquePeer([.updateEditChannelMessage(.init(message: edited, pts: 51, ptsCount: 1))], opaqueChat: true))
    check(TLParser.editHistory(forId: 114, peer: NSNumber(value: peer)) == ["Channel \(channelId)", "Edited channel \(channelId)"], "Fallback histories never collide across channels")
}
let outgoing = message(115, text: "My message")
messageData(outgoing).flags |= 1 << 1
_ = TLParser.stripAntiSelfDestruct(updatesWithOpaquePeer([.updateNewMessage(.init(message: outgoing, pts: 50, ptsCount: 1))]))
let outgoingEdit = message(115, text: "My revised message", edit: 1235)
messageData(outgoingEdit).flags |= 1 << 1
let outgoingBytes = updatesWithOpaquePeer([.updateEditMessage(.init(message: outgoingEdit, pts: 51, ptsCount: 1))])
check(TLParser.stripAntiSelfDestruct(outgoingBytes) == nil, "Recording an outgoing edit preserves host editing behavior")
check(TLParser.editHistory(forId: 115, peer: 42) == ["My message", "My revised message"], "Track outgoing originals and edits")

flags("TGExtraAntiEdit")
for (id, texts) in [(Int32(130), ["A", "B", "A", "C"]),
                    (131, ["Caption", "", "Caption"]), (132, ["", "Caption", ""])] {
    _ = patch(Api.Update.updateNewChannelMessage(.init(message: message(id, text: texts[0]), pts: 50, ptsCount: 1)))
    for (index, text) in texts.dropFirst().enumerated() {
        let edit = message(id, text: text, edit: 1235 + Int32(index))
        let update = Api.Update.updateEditChannelMessage(.init(message: edit, pts: 51 + Int32(index), ptsCount: 1))
        check(patch(update) == nil, "Tracking never changes the edited message bytes")
        _ = patch(update) // A duplicate delivery is not a new revision.
    }
    check(TLParser.editHistory(forId: NSNumber(value: id), peer: 42) == texts, "Keep reversions and empty captions without duplicate versions")
}
_ = patch(message(133, text: "Original"))
_ = patch(message(133, text: "Different text without edit_date"))
check(TLParser.editHistory(forId: 133, peer: 42) == nil, "Unmarked text changes do not create false edit histories")

let historyState = Api.updates.State.state(.init(pts: 50, qts: 0, date: 1234, seq: 8, unreadCount: 0))
let historySearchFlood = Api.SearchPostsFlood.searchPostsFlood(.init(flags: 2, totalDaily: 10, remains: 5, waitTill: 1234, starsAmount: 0))
let historySettings = Api.PeerNotifySettings.peerNotifySettings(.init(flags: 0,
    showPreviews: nil, silent: nil, muteUntil: nil, iosSound: nil, androidSound: nil, otherSound: nil,
    storiesMuted: nil, storiesHideSender: nil, storiesIosSound: nil, storiesAndroidSound: nil, storiesOtherSound: nil))
let historyDialog = Api.Dialog.dialog(.init(flags: 0, peer: .peerChannel(.init(channelId: 77)),
    topMessage: 1, readInboxMaxId: 0, readOutboxMaxId: 0, unreadCount: 0, unreadMentionsCount: 0,
    unreadReactionsCount: 0, unreadPollVotesCount: 0, notifySettings: historySettings,
    pts: nil, draft: nil, folderId: nil, ttlPeriod: nil))
let historyReplies: [(name: String, suffix: Int, wrap: ([Api.Message], [Api.Update]) -> Any)] = [
    ("messages", 0, { msgs, _ in Api.messages.Messages.messages(.init(messages: msgs, topics: [], chats: [], users: [])) }),
    ("messagesSlice", 0, { msgs, _ in Api.messages.Messages.messagesSlice(.init(flags: 13, count: 1, nextRate: 2, offsetIdOffset: 3, searchFlood: historySearchFlood, messages: msgs, topics: [], chats: [], users: [])) }),
    ("channelMessages", 0, { msgs, _ in Api.messages.Messages.channelMessages(.init(flags: 4, pts: 50, count: 1, offsetIdOffset: 3, messages: msgs, topics: [], chats: [], users: [])) }),
    ("discussionMessage", 0, { msgs, _ in Api.messages.DiscussionMessage.discussionMessage(.init(flags: 7, messages: msgs, maxId: 9, readInboxMaxId: 8, readOutboxMaxId: 7, unreadCount: 0, chats: [], users: [])) }),
    ("peerDialogs", 24, { msgs, _ in Api.messages.PeerDialogs.peerDialogs(.init(dialogs: [historyDialog], messages: msgs, chats: [], users: [], state: historyState)) }),
    ("dialogs", 0, { msgs, _ in Api.messages.Dialogs.dialogs(.init(dialogs: [historyDialog], messages: msgs, chats: [], users: [])) }),
    ("dialogsSlice", 0, { msgs, _ in Api.messages.Dialogs.dialogsSlice(.init(count: 1, dialogs: [historyDialog], messages: msgs, chats: [], users: [])) }),
    ("channelDifference", 0, { msgs, updates in Api.updates.ChannelDifference.channelDifference(.init(flags: 2, pts: 50, timeout: 10, newMessages: msgs, otherUpdates: updates, chats: [], users: [])) }),
    ("channelDifferenceTooLong", 0, { msgs, _ in Api.updates.ChannelDifference.channelDifferenceTooLong(.init(flags: 2, timeout: 10, dialog: historyDialog, messages: msgs, chats: [], users: [])) }),
    ("difference", 24, { msgs, updates in Api.updates.Difference.difference(.init(newMessages: msgs, newEncryptedMessages: [], otherUpdates: updates, chats: [], users: [], state: historyState)) }),
    ("differenceSlice", 24, { msgs, updates in Api.updates.Difference.differenceSlice(.init(newMessages: msgs, newEncryptedMessages: [], otherUpdates: updates, chats: [], users: [], intermediateState: historyState)) })
]
func withOpaqueHistoryPeer(_ value: Any, suffix: Int, user: Bool) -> NSData {
    let bytes = serialized(value)
    let offset = bytes.length - suffix - (user ? 8 : 16)
    let result = NSMutableData(data: bytes as Data)
    var count: Int32 = 1
    result.replaceBytes(in: NSRange(location: offset + 4, length: 4), withBytes: &count)
    let peer = Buffer()
    peer.appendInt32(1234567)
    peer.appendInt32(0)
    result.replaceBytes(in: NSRange(location: offset + 8, length: 0), withBytes: peer.data!, length: Int(peer.size))
    return result
}
for (index, reply) in historyReplies.enumerated() {
    for variant in 0...2 { // Known peers, an unknown Chat, an unknown User.
        let id = Int32(200 + index * 3 + variant)
        func deliver(_ msgs: [Api.Message], updates: [Api.Update] = []) {
            let value = reply.wrap(msgs, updates)
            let bytes = variant == 0 ? serialized(value)
                : withOpaqueHistoryPeer(value, suffix: reply.suffix, user: variant == 2)
            check(TLParser.handleResponse(bytes, functionID: 1) == nil, "\(reply.name) tracks versions without changing response bytes")
        }
        deliver([message(id, text: "Before")])
        deliver([message(id, text: "After", edit: 1235)])
        check(TLParser.editHistory(forId: NSNumber(value: id), peer: 42) == ["Before", "After"], "\(reply.name) tracks loaded messages with known or opaque peers")
        if ["channelDifference", "difference", "differenceSlice"].contains(reply.name) {
            deliver([], updates: [.updateEditMessage(.init(message: message(id, text: "Another edit", edit: 1236), pts: 52, ptsCount: 1))])
            check(TLParser.editHistory(forId: NSNumber(value: id), peer: 42) == ["Before", "After", "Another edit"], "Difference fallback tracks otherUpdates too")
        }
    }
    let rejectedId = Int32(300 + index)
    let valid = serialized(reply.wrap([message(rejectedId)], []))
    // No unknown peer: every truncated prefix must be rejected without recording.
    for length in 0..<valid.length {
        _ = TLParser.stripAntiSelfDestruct((valid as Data).prefix(length) as NSData)
    }
    let malformed = NSMutableData(data: valid as Data)
    var negativeCount: Int32 = -1
    malformed.replaceBytes(in: NSRange(location: valid.length - reply.suffix - 12, length: 4), withBytes: &negativeCount)
    _ = TLParser.stripAntiSelfDestruct(malformed)
    _ = patch(message(rejectedId, text: "First valid sighting", edit: 1235))
    check(TLParser.editHistory(forId: NSNumber(value: rejectedId), peer: 42) == nil, "Rejected \(reply.name) replies never record partial history")
}

for id in Int32(10_000)...Int32(12_100) { _ = patch(message(id, text: "Unedited")) }
check(TLParser.editHistory(forId: 40, peer: 42) == ["Original 😀", "New text"], "Unrelated message traffic never evicts recorded edits")
_ = patch(message(12_100, text: "Edited after cache churn", edit: 1235))
let savedHistories = defaults.dictionary(forKey: "TGExtraEditHistoryByPeer") as! [String: [String]]
check(savedHistories["42:40"] == ["Original 😀", "New text"], "Protected histories remain persisted after cache churn")
check(savedHistories["42:10000"] == nil, "Unedited original cache stays bounded")
check(savedHistories.values.filter { $0.count == 1 }.count <= 2000, "Only unedited originals count toward the cache limit")
print("PASS history retention, reversions, empty captions, outgoing edits and all history/difference containers")

flags("TGExtraAntiRevoke")
let updateBytes = serialized(deletion([50])) as Data
func gzip(_ input: Data) -> Data {
    var stream = z_stream()
    check(deflateInit2_(&stream, Z_DEFAULT_COMPRESSION, Z_DEFLATED, 31, 8, Z_DEFAULT_STRATEGY, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK, "Start gzip")
    defer { deflateEnd(&stream) }
    var output = Data(count: 4096)
    input.withUnsafeBytes { inputBytes in
        output.withUnsafeMutableBytes { outputBytes in
            stream.next_in = UnsafeMutablePointer(mutating: inputBytes.baseAddress!.assumingMemoryBound(to: UInt8.self))
            stream.avail_in = uInt(input.count)
            stream.next_out = outputBytes.baseAddress!.assumingMemoryBound(to: UInt8.self)
            stream.avail_out = uInt(outputBytes.count)
            check(deflate(&stream, Z_FINISH) == Z_STREAM_END, "Complete gzip")
        }
    }
    return output.prefix(Int(stream.total_out))
}
let packed = Buffer()
packed.appendInt32(0x3072cfa1)
serializeBytes(Buffer(data: gzip(updateBytes)), buffer: packed, boxed: false)
check(deletionIds(parsed(TLParser.handleResponse(packed.makeData() as NSData, functionID: 1)!, as: Api.Update.self)) == [0], "Patch gzipped RPC replies")
let packedOpaque = Buffer()
packedOpaque.appendInt32(0x3072cfa1)
serializeBytes(Buffer(data: gzip(updatesWithOpaquePeer([deletion([116])]) as Data)), buffer: packedOpaque, boxed: false)
let unpackedOpaque = TLParser.stripAntiSelfDestruct(packedOpaque.makeData() as NSData)!
let opaqueReader = BufferReader(Buffer(nsData: unpackedOpaque))
opaqueReader.skip(12)
check(deletionIds(Api.parse(opaqueReader, signature: opaqueReader.readInt32()!) as! Api.Update) == [0], "Apply the fallback inside gzip wrappers")
let container = Buffer()
container.appendInt32(0x73f1f8dc); container.appendInt32(1)
container.appendInt64(123); container.appendInt32(1); container.appendInt32(Int32(updateBytes.count))
updateBytes.withUnsafeBytes { container.appendBytes($0.baseAddress!, length: UInt($0.count)) }
let rewrittenContainer = TLParser.stripAntiSelfDestruct(container.makeData() as NSData)!
let containerReader = BufferReader(Buffer(nsData: rewrittenContainer))
check(containerReader.readInt32() == 0x73f1f8dc && containerReader.readInt32() == 1, "Preserve container framing")
check(containerReader.readInt64() == 123 && containerReader.readInt32() == 1, "Preserve transport metadata")
let body = containerReader.readBuffer(Int(containerReader.readInt32()!))!
check(deletionIds(parsed(body.makeData() as NSData, as: Api.Update.self)) == [0], "Patch nested container body")
for length in 0..<updateBytes.count {
    check(TLParser.stripAntiSelfDestruct(updateBytes.prefix(length) as NSData) == nil, "Truncated updates pass through")
}
let unknown = Buffer(); unknown.appendInt32(1234567)
check(TLParser.stripAntiSelfDestruct(unknown.makeData() as NSData) == nil, "Unknown constructors pass through")
let malformed = Buffer(); malformed.appendInt32(0x73f1f8dc); malformed.appendInt32(-1)
check(TLParser.stripAntiSelfDestruct(malformed.makeData() as NSData) == nil, "Negative container counts pass through")

flags("TGExtraVideoToVoice")
let inputPeer = Api.InputPeer.inputPeerUser(.init(userId: 42, accessHash: 3))
let file = Api.InputFile.inputFile(.init(id: 123, parts: 1, name: "tgextra-voice.m4a", md5Checksum: "hash"))
let media = Api.InputMedia.inputMediaUploadedDocument(.init(flags: 0, file: file, thumb: nil, mimeType: "audio/mp4", attributes: [.documentAttributeFilename(.init(fileName: "tgextra-voice.m4a"))], stickers: nil, videoCover: nil, videoTimestamp: nil, ttlSeconds: nil))
let request = Api.functions.messages.sendMedia(flags: 0, peer: inputPeer, replyTo: nil, media: media, message: "caption", randomId: 999, replyMarkup: nil, entities: nil, scheduleDate: nil, scheduleRepeatPeriod: nil, sendAs: nil, quickReplyShortcut: nil, effect: nil, allowPaidStars: nil, suggestedPost: nil).1
check(TLParser.rewriteVoiceUpload(request.makeData() as NSData) == nil, "Ordinary files are untouched")
TLParser.registerVoiceUpload(withFileName: "tgextra-voice.m4a", duration: 7, waveform: Data([1, 2, 3]) as NSData)
let voice = TLParser.rewriteVoiceUpload(request.makeData() as NSData)!
let voiceReader = BufferReader(Buffer(nsData: voice))
check(voiceReader.readInt32() == 53536639 && voiceReader.readInt32() == 0, "Keep outgoing request header")
_ = Api.parse(voiceReader, signature: voiceReader.readInt32()!) as! Api.InputPeer
let voiceMedia = Api.parse(voiceReader, signature: voiceReader.readInt32()!) as! Api.InputMedia
guard case let .inputMediaUploadedDocument(upload) = voiceMedia,
      case let .documentAttributeAudio(audio) = upload.attributes.first! else { fatalError("Expected voice attribute") }
check(audio.duration == 7 && audio.flags & (1 << 10) != 0 && audio.waveform?.size == 2, "Send measured duration and packed waveform as voice")
check(parseString(voiceReader) == "caption" && voiceReader.readInt64() == 999, "Keep request fields after media unchanged")
flags()
check(TLParser.rewriteVoiceUpload(request.makeData() as NSData) == nil, "Video-to-voice toggle disables rewriting")
print("PASS TL updates (including opaque peer metadata), auto-delete, disappearing media, edits, gzip, containers and voice uploads")
