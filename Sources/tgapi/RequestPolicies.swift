import Foundation
import tgapiC

extension TLParser {
    static let typingSettings = [
        "sendMessageTypingAction": "disableTypingStatus",
        "sendMessageRecordVideoAction": "disableRecordingVideoStatus",
        "sendMessageUploadVideoAction": "disableUploadingVideoStatus",
        "sendMessageRecordAudioAction": "disableRecordingVoiceStatus",
        "sendMessageUploadAudioAction": "disableUploadingVoiceStatus",
        "sendMessageUploadPhotoAction": "disableUploadingPhotoStatus",
        "sendMessageUploadDocumentAction": "disableUploadingFileStatus",
        "sendMessageGeoLocationAction": "disableChoosingLocationStatus",
        "sendMessageChooseContactAction": "disableChoosingContactStatus",
        "sendMessageGamePlayAction": "disablePlayingGameStatus",
        "sendMessageRecordRoundAction": "disableRecordingRoundVideoStatus",
        "sendMessageUploadRoundAction": "disableUploadingRoundVideoStatus",
        "speakingInGroupCallAction": "disableSpeakingInGroupCallStatus",
        "sendMessageHistoryImportAction": "reserverHistroyImport",
        "sendMessageChooseStickerAction": "disableChoosingStickerStatus",
        "sendMessageEmojiInteraction": "disableEmojiInteractionStatus",
        "sendMessageEmojiInteractionSeen": "disableEmojiAcknowledgementStatus",
    ]

    static func exceptionPeer(_ record: TLRecord) -> Bool {
        guard let peer = record["peer"] as? TLRecord,
              ["inputPeerUser", "inputPeerUserFromMessage"].contains(peer.constructorName),
              let userId = peer["userId"] as? Int64 else { return false }
        return TGExtraIsGhostException(userId)
    }

    @objc static func fakeResponseForPayload(_ payload: NSData) -> NSData? {
        guard let method = requestMethod(payload) else { return nil }
        let defaults = UserDefaults.standard
        let ghost = defaults.bool(forKey: "TGExtraGhostModeEnabled")
        let constructor: String
        switch method {
        case .accountUpdateStatus:
            guard ghost, defaults.bool(forKey: "disableOnlineStatus"), let record = request(payload),
                  let offline = record["offline"] as? TLRecord, offline.constructorName == "boolFalse" else { return nil }
            constructor = "boolTrue"
        case .messagesSetTyping:
            guard ghost, let record = request(payload), !exceptionPeer(record),
                  let action = record["action"] as? TLRecord, let key = typingSettings[action.constructorName],
                  defaults.bool(forKey: key) else { return nil }
            constructor = "boolTrue"
        case .messagesReadHistory, .channelsReadHistory:
            guard ghost, defaults.bool(forKey: "disableMessageReadReceipt"),
                  let record = request(payload), !exceptionPeer(record) else { return nil }
            constructor = method == .messagesReadHistory ? "affectedMessages" : "boolTrue"
        case .messagesReadMentions, .messagesReadReactions:
            let key = method == .messagesReadMentions ? "disableMentionReadReceipt" : "disableReactionReadReceipt"
            guard ghost, defaults.bool(forKey: key), let record = request(payload), !exceptionPeer(record) else { return nil }
            constructor = "affectedHistory"
        case .storiesReadStories:
            guard ghost, defaults.bool(forKey: "disableStoriesReadReceipt"),
                  let record = request(payload), !exceptionPeer(record) else { return nil }
            constructor = "vector"
        case .messagesGetSponsoredMessages:
            guard defaults.bool(forKey: "disableAllAds"), request(payload) != nil else { return nil }
            constructor = "sponsoredMessagesEmpty"
        case .messagesSendScreenshotNotification:
            guard defaults.bool(forKey: "TGExtraDisableScreenshotNotification"), request(payload) != nil else { return nil }
            constructor = "updates"
        default: return nil
        }
        return emptyResponse(method: method, constructor: constructor)
    }

    @objc static func rewriteRequestPayload(_ payload: NSData) -> NSData? {
        switch requestMethod(payload) {
        case .helpGetAppConfig: return rewriteAppConfigRequest(payload)
        case .messagesSendMedia, .messagesUploadMedia, .messagesSendMultiMedia: return rewriteVoiceUpload(payload)
        default: return nil
        }
    }
}
