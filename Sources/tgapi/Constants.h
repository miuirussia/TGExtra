#import <Foundation/Foundation.h>

#define kAccountUpdateOnlineStatus 1713919532
#define kMessagesSetTypingAction 1486110434
#define kMessagesReadHistory 238054714
#define kMessagesReadMentions 921026381
#define kMessagesReadReactions -1631301741
#define kStoriesReadStories -1521034552
#define kGetSponsoredMessages 1030547536
#define kGetAppConfig 1642330196
#define kSendScreenshotNotification -1589618665
// Content reads acknowledge mentions/reactions/playback and open TTL media.
#define kMessagesReadMessageContents 916930423
#define kChannelsReadMessageContents -357180360

// Outgoing media sends, rewritten by Video to Voice
#define kMessagesSendMedia 53536639
#define kMessagesSendMultiMedia 469278068
#define kMessagesUploadMedia 345405816

#define kActionIDTyping 381645902           // .sendMessageTypingAction
#define kActionIDRecordingVideo -1584933265 // .sendMessageRecordVideoAction
#define kActionIDUploadingVideo -378127636  // .sendMessageUploadVideoAction
#define kActionIDRecordingAudio -718310409  // .sendMessageRecordAudioAction
#define kActionIDUploadingVoice -212740181  // .sendMessageUploadAudioAction
#define kActionIDUploadingPhoto -774682074  // .sendMessageUploadPhotoAction
#define kActionIDUploadingFile -1441998364  // .sendMessageUploadDocumentAction
#define kActionIDChoosingLocation 393186209 // .sendMessageGeoLocationAction
#define kActionIDChoosingContact 1653390447 // .sendMessageChooseContactAction
#define kActionIDPlayingGame -580219064     // .sendMessageGamePlayAction
#define kActionIDRecordingRoundVideo                                           \
  -1997373508                                   // .sendMessageRecordRoundAction
#define kActionIDUploadingRoundVideo 608050278  // .sendMessageUploadRoundAction
#define kActionIDSpeakingInGroupCall -651419003 // .speakingInGroupCallAction
#define kActionIDReserverHistoryImport                                         \
  -606432698                                 // .sendMessageHistoryImportAction
#define kActionIDChoosingSticker -1336228175 // .sendMessageChooseStickerAction
#define kActionIDEmojiInteraction 630664139  // .sendMessageEmojiInteraction
#define kActionIDEmojiAcknowledgement                                          \
  -1234857938 // .sendMessageEmojiInteractionSeen

#define kGhostModeEnabled @"TGExtraGhostModeEnabled"
#define kGhostDetailsToggle @"TGExtraGhostDetailsToggle"
#define kDisableOnlineStatus @"disableOnlineStatus"

#define kDisableTypingStatus @"disableTypingStatus"
#define kDisableRecordingVideoStatus @"disableRecordingVideoStatus"
#define kDisableUploadingVideoStatus @"disableUploadingVideoStatus"
#define kDisableRecordingVoiceStatus @"disableRecordingVoiceStatus"
#define kDisableUploadingVoiceStatus @"disableUploadingVoiceStatus"
#define kDisableUploadingPhotoStatus @"disableUploadingPhotoStatus"
#define kDisableUploadingFileStatus @"disableUploadingFileStatus"
#define kDisableChoosingLocationStatus @"disableChoosingLocationStatus"
#define kDisableChoosingContactStatus @"disableChoosingContactStatus"
#define kDisablePlayingGameStatus @"disablePlayingGameStatus"
#define kDisableRecordingRoundVideoStatus @"disableRecordingRoundVideoStatus"
#define kDisableUploadingRoundVideoStatus @"disableUploadingRoundVideoStatus"
#define kDisableSpeakingInGroupCallStatus @"disableSpeakingInGroupCallStatus"
#define kDisableChoosingStickerStatus @"disableChoosingStickerStatus"
#define kDisableEmojiInteractionStatus @"disableEmojiInteractionStatus"
#define kDisableEmojiAcknowledgementStatus @"disableEmojiAcknowledgementStatus"

#define kDisableMessageReadReceipt @"disableMessageReadReceipt"
#define kDisableReactionReadReceipt @"disableReactionReadReceipt"
#define kDisableMentionReadReceipt @"disableMentionReadReceipt"
#define kDisableStoriesReadReceipt @"disableStoriesReadReceipt"
#define kDisableScreenshotNotification @"TGExtraDisableScreenshotNotification"

// FIX: was incorrectly mapped to "disableOnlineStatus" — now has its own key
#define kDisableAllAds @"disableAllAds"
#define kDisableForwardRestriction @"disableForwardRestriction"
#define kIgnorePrivateChatCopyProtection @"TGExtraIgnorePrivateChatCopyProtection"

// Anti-features
#define kAntiRevoke @"TGExtraAntiRevoke"
#define kAntiEdit @"TGExtraAntiEdit"
// Key for preventing disappearing/self-destruct media from being marked as read
#define kAntiSelfDestruct @"TGExtraAntiSelfDestruct"
#define kAntiAutoDelete @"TGExtraAntiAutoDelete"

#define FAKE_LOCATION_ENABLED_KEY @"TGExtraFakeLocation"
#define FAKE_LATITUDE_KEY @"TGExtraSavedLatitude"
#define FAKE_LONGITUDE_KEY @"TGExtraSavedLongitude"

#define FILE_PICKER_FIX_KEY @"TGExtraFixFilePicker"
#define FILE_PICKER_PATH @"TGExtraFileFixUsingSomeUglyHacks"



// Video to Voice: strip the video track off a picked video and send only its
// audio. Honours the trim handles set in the preview.
#define kVideoToVoice @"TGExtraVideoToVoice"

// Ghost Exceptions: peers that keep seeing your real typing/read activity
// while Ghost Mode stays enabled for everyone else.
#define kGhostExceptions @"TGExtraGhostExceptions"

// Hide the "dissapearing message" marker prepended to intercepted TTL media
#define kHideDisappearingLabel @"TGExtraHideDisappearingLabel"
