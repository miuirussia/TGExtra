import Foundation
import TestSupport
import zlib

let defaults = TGExtraUseTestDefaults()!
precondition(UserDefaults.standard === defaults, "Tests must use in-memory defaults")
if CommandLine.arguments.contains("--restore") {
    defaults.set(["42:40": ["Before", "After"]], forKey: "TGExtraEditHistoryByPeer")
    defaults.set(["10": [NSNumber(value: 0)]], forKey: "TGExtraDeletedMsgIds")
    defaults.set(["20": [NSNumber(value: 0)]], forKey: "TGExtraAutoDeleteMsgIds")
    defaults.set(true, forKey: "TGExtraAntiAutoDelete")
    defaults.set(999, forKey: "TGExtraLastKnownUserId")
    TLParser.loadPersistedIds()
    precondition(TLParser.editHistory(forId: 40, peer: 42) == ["Before", "After"])
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
let revoked = parsed(patch(deletion([10, 11]))!, as: Api.Update.self)
check(deletionIds(revoked) == [0, 0], "Retain deleted messages")
check(TLParser.isDeleted(10, peer: 42), "Deletion marker is scoped to private chats")
check(!TLParser.isDeleted(10, peer: -1_000_000_000_077), "Private deletion never marks a channel")
let channelDeleted = parsed(patch(deletion([10], channel: 77))!, as: Api.Update.self)
check(deletionIds(channelDeleted) == [0], "Retain channel deletion")
check(!TLParser.isDeleted(10, peer: -1_000_000_000_078), "Repeated channel message IDs stay independent")
flags()
check(patch(deletion([12])) == nil, "Disabled anti-revoke passes through")

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

flags("TGExtraAntiEdit")
let original = message(40)
_ = patch(Api.Update.updateNewMessage(.init(message: original, pts: 50, ptsCount: 1)))
let edited = message(40, text: "New text", edit: 1235)
check(patch(Api.Update.updateEditMessage(.init(message: edited, pts: 51, ptsCount: 1))) == nil, "Keep latest edited text in the chat")
check(TLParser.editHistory(forId: 40, peer: 42) == ["Original 😀", "New text"], "Keep original and revised text")
check(TLParser.editHistory(forId: 40, peer: 43) == nil, "Never mix edit histories across peers")
check(defaults.dictionary(forKey: "TGExtraEditHistoryByPeer") != nil, "Persist edit history immediately")

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
print("PASS TL updates, auto-delete, disappearing media, edits, gzip, containers and voice uploads")
