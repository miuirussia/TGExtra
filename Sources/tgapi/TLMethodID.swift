import Foundation

// The single catalog of methods used by TGExtra. Numeric IDs always come from
// the installed client's schema; absent methods have no fallback ID.
enum TLMethodID: String, CaseIterable {
    case accountUpdateStatus = "account.updateStatus"
    case messagesGetMessages = "messages.getMessages"
    case channelsGetMessages = "channels.getMessages"
    case messagesGetScheduledHistory = "messages.getScheduledHistory"
    case messagesGetScheduledMessages = "messages.getScheduledMessages"
    case messagesGetQuickReplyMessages = "messages.getQuickReplyMessages"
    case usersGetFullUser = "users.getFullUser"
    case usersGetUsers = "users.getUsers"
    case contactsResolveUsername = "contacts.resolveUsername"
    case messagesReadContents = "messages.readMessageContents"
    case channelsReadContents = "channels.readMessageContents"
    case messagesForward = "messages.forwardMessages"
    case messagesSendMedia = "messages.sendMedia"
    case messagesUploadMedia = "messages.uploadMedia"
    case messagesSendMultiMedia = "messages.sendMultiMedia"
    case messagesSendMessage = "messages.sendMessage"
    case messagesSetTyping = "messages.setTyping"
    case messagesReadHistory = "messages.readHistory"
    case channelsReadHistory = "channels.readHistory"
    case messagesReadMentions = "messages.readMentions"
    case messagesReadReactions = "messages.readReactions"
    case storiesReadStories = "stories.readStories"
    case messagesGetSponsoredMessages = "messages.getSponsoredMessages"
    case messagesSendScreenshotNotification = "messages.sendScreenshotNotification"
    case helpGetAppConfig = "help.getAppConfig"
    case helpGetNearestDc = "help.getNearestDc"
    case uploadGetFile = "upload.getFile"
    case uploadSaveBigFilePart = "upload.saveBigFilePart"
    case uploadSaveFilePart = "upload.saveFilePart"

    var id: Int32? { HostSchema.shared?.functions[rawValue]?.signature }

    init?(signature: Int32) {
        guard let name = HostSchema.shared?.functionsBySignature[signature]?.name else { return nil }
        self.init(rawValue: name)
    }

    static func resolve(_ payload: NSData) -> TLMethodID? {
        guard payload.length >= 4 else { return nil }
        var signature = Int32(0)
        payload.getBytes(&signature, length: 4)
        return TLMethodID(signature: Int32(littleEndian: signature))
    }
}

extension TLRecord {
    convenience init(function: TLMethodID) { self.init(function: function.rawValue) }

    var method: TLMethodID? { typeName == "!Function" ? TLMethodID(rawValue: constructorName) : nil }
}

extension TLParser {
    static func requestMethod(_ payload: NSData) -> TLMethodID? { TLMethodID.resolve(payload) }
}
