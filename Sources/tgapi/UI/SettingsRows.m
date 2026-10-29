#import "SettingsRows.h"
#import "../Constants.h"

@implementation TGExtraSettingRow
+ (instancetype)rowWithKey:(NSString *)key title:(NSString *)title subtitle:(NSString *)subtitle icon:(NSString *)icon {
    TGExtraSettingRow *row = [self new];
    row->_key = key;
    row->_titleKey = title;
    row->_subtitleKey = subtitle;
    row->_icon = icon;
    return row;
}

+ (NSArray<TGExtraSettingRow *> *)ghostRows {
    static NSArray *rows;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        rows = @[
            [self rowWithKey:kDisableOnlineStatus title:@"DISABLE_ONLINE_STATUS_TITLE"
                subtitle:@"DISABLE_ONLINE_STATUS_SUBTITLE" icon:@""],
            [self rowWithKey:kDisableTypingStatus title:@"DISABLE_TYPING_STATUS_TITLE"
                subtitle:@"DISABLE_TYPING_STATUS_SUBTITLE" icon:@""],
            [self rowWithKey:kDisableRecordingVideoStatus title:@"DISABLE_RECORDING_VIDEO_STATUS_TITLE"
                subtitle:@"DISABLE_RECORDING_VIDEO_STATUS_SUBTITLE" icon:@""],
            [self rowWithKey:kDisableUploadingVideoStatus title:@"DISABLE_UPLOADING_VIDEO_STATUS_TITLE"
                subtitle:@"DISABLE_UPLOADING_VIDEO_STATUS_SUBTITLE" icon:@""],
            [self rowWithKey:kDisableRecordingVoiceStatus title:@"DISABLE_VC_MESSAGE_RECORDING_STATUS_TITLE"
                subtitle:@"DISABLE_VC_MESSAGE_RECORDING_STATUS_SUBTITLE" icon:@""],
            [self rowWithKey:kDisableUploadingVoiceStatus title:@"DISABLE_VC_MESSAGE_UPLOADING_STATUS_TITLE"
                subtitle:@"DISABLE_VC_MESSAGE_UPLOADING_STATUS_SUBTITLE" icon:@""],
            [self rowWithKey:kDisableUploadingPhotoStatus title:@"DISABLE_UPLOADING_PHOTO_STATUS_TITLE"
                subtitle:@"DISABLE_UPLOADING_PHOTO_STATUS_SUBTITLE" icon:@""],
            [self rowWithKey:kDisableUploadingFileStatus title:@"DISABLE_UPLOADING_FILE_STATUS_TITLE"
                subtitle:@"DISABLE_UPLOADING_FILE_STATUS_SUBTITLE" icon:@""],
            [self rowWithKey:kDisableChoosingLocationStatus title:@"DISABLE_CHOOSING_LOCATION_STATUS_TITLE"
                subtitle:@"DISABLE_CHOOSING_LOCATION_STATUS_SUBTITLE" icon:@""],
            [self rowWithKey:kDisableChoosingContactStatus title:@"DISABLE_CHOOSING_CONTACT_TITLE"
                subtitle:@"DISABLE_CHOOSING_CONTACT_SUBTITLE" icon:@""],
            [self rowWithKey:kDisablePlayingGameStatus title:@"DISABLE_PLAYING_GAME_STATUS_TITLE"
                subtitle:@"DISABLE_PLAYING_GAME_STATUS_SUBTITLE" icon:@""],
            [self rowWithKey:kDisableRecordingRoundVideoStatus title:@"DISABLE_RECORDING_ROUND_VIDEO_STATUS_TITLE"
                subtitle:@"DISABLE_RECORDING_ROUND_VIDEO_STATUS_SUBTITLE" icon:@""],
            [self rowWithKey:kDisableUploadingRoundVideoStatus title:@"DISABLE_UPLOADING_ROUND_VIDEO_STATUS_TITLE"
                subtitle:@"DISABLE_UPLOADING_ROUND_VIDEO_STATUS_SUBTITLE" icon:@""],
            [self rowWithKey:kDisableSpeakingInGroupCallStatus title:@"DISABLE_SPEAKING_IN_GROUP_CALL_STATUS_TITLE"
                subtitle:@"DISABLE_SPEAKING_IN_GROUP_CALL_STATUS_SUBTITLE" icon:@""],
            [self rowWithKey:kDisableChoosingStickerStatus title:@"DISABLE_CHOOSING_STICKER_STATUS_TITLE"
                subtitle:@"DISABLE_CHOOSING_STICKER_STATUS_SUBTITLE" icon:@""],
            [self rowWithKey:kDisableEmojiInteractionStatus title:@"DISABLE_EMOJI_INTERACTION_STATUS_TITLE"
                subtitle:@"DISABLE_EMOJI_INTERACTION_STATUS_SUBTITLE" icon:@""],
            [self rowWithKey:kDisableEmojiAcknowledgementStatus title:@"DISABLE_EMOJI_ACKNOWLEDGEMENT_STATUS_TITLE"
                subtitle:@"DISABLE_EMOJI_ACKNOWLEDGEMENT_STATUS_SUBTITLE" icon:@""],
            [self rowWithKey:kDisableMessageReadReceipt title:@"DISABLE_MESSAGE_READ_RECEIPT_TITLE"
                subtitle:@"DISABLE_MESSAGE_READ_RECEIPT_SUBTITLE" icon:@""],
            [self rowWithKey:kDisableReactionReadReceipt title:@"DISABLE_REACTION_READ_RECEIPT_TITLE"
                subtitle:@"DISABLE_REACTION_READ_RECEIPT_SUBTITLE" icon:@""],
            [self rowWithKey:kDisableMentionReadReceipt title:@"DISABLE_MENTION_READ_RECEIPT_TITLE"
                subtitle:@"DISABLE_MENTION_READ_RECEIPT_SUBTITLE" icon:@""],
            [self rowWithKey:kDisableStoriesReadReceipt title:@"DISABLE_STORY_READ_RECEIPT_TITLE"
                subtitle:@"DISABLE_STORY_READ_RECEIPT_SUBTITLE" icon:@""],
        ];
    });
    return rows;
}

+ (NSArray<TGExtraSettingRow *> *)featureRowsForSection:(NSInteger)section {
    static NSDictionary<NSNumber *, NSArray<TGExtraSettingRow *> *> *sections;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        sections = @{
        @(MESSAGE_HISTORY): @[
            [self rowWithKey:kAntiRevoke title:@"ANTI_REVOKE_TITLE"
                subtitle:@"ANTI_REVOKE_SUBTITLE" icon:@"trash.slash.fill"],
            [self rowWithKey:kAntiAutoDelete title:@"ANTI_AUTO_DELETE_TITLE"
                subtitle:@"ANTI_AUTO_DELETE_SUBTITLE" icon:@"clock.arrow.circlepath"],
            [self rowWithKey:kAntiEdit title:@"ANTI_EDIT_TITLE"
                subtitle:@"ANTI_EDIT_SUBTITLE" icon:@"pencil.slash"],
        ],
        @(CONTENT_ACCESS): @[
            [self rowWithKey:kDisableForwardRestriction title:@"ENABLE_SAVING_PROTECTED_CONTENT_TITLE"
                subtitle:@"ENABLE_SAVING_PROTECTED_CONTENT_SUBTITLE" icon:@"lock.open.fill"],
            [self rowWithKey:kIgnorePrivateChatCopyProtection title:@"IGNORE_PRIVATE_COPY_PROTECTION_TITLE"
                subtitle:@"IGNORE_PRIVATE_COPY_PROTECTION_SUBTITLE" icon:@"doc.on.doc"],
            [self rowWithKey:kDisableScreenshotNotification title:@"ANTI_SCREENSHOT_TITLE"
                subtitle:@"ANTI_SCREENSHOT_SUBTITLE" icon:@"camera.fill"],
            [self rowWithKey:kAntiSelfDestruct title:@"ANTI_SELF_DESTRUCT_TITLE"
                subtitle:@"ANTI_SELF_DESTRUCT_SUBTITLE" icon:@"eye.fill"],
            [self rowWithKey:kHideDisappearingLabel title:@"HIDE_DISAPPEARING_LABEL_TITLE"
                subtitle:@"HIDE_DISAPPEARING_LABEL_SUBTITLE" icon:@"text.badge.xmark"],
        ],
        @(MEDIA): @[
            [self rowWithKey:kVideoToVoice title:@"VIDEO_TO_VOICE_TITLE"
                subtitle:@"VIDEO_TO_VOICE_SUBTITLE" icon:@"waveform.circle.fill"],
            [self rowWithKey:kForceTLottie title:@"FORCE_TLOTTIE_TITLE"
                subtitle:@"FORCE_TLOTTIE_SUBTITLE" icon:@"play.rectangle"],
        ],
        @(INTERFACE): @[
            [self rowWithKey:kDisableAllAds title:@"DISABLE_ALL_ADS_TITLE"
                subtitle:@"DISABLE_ALL_ADS_SUBTITLE" icon:@"nosign"],
            [self rowWithKey:kDisableDoubleTapReactions title:@"DISABLE_DOUBLE_TAP_REACTIONS_TITLE"
                subtitle:@"DISABLE_DOUBLE_TAP_REACTIONS_SUBTITLE" icon:@"hand.tap"],
        ],
        };
    });
    return sections[@(section)];
}

+ (TGExtraSettingRow *)rowForSection:(NSInteger)section row:(NSInteger)row {
    NSArray<TGExtraSettingRow *> *rows = [self featureRowsForSection:section];
    if (section == GHOST_MODE) {
        if (row == 0) return [self rowWithKey:kGhostModeEnabled title:@"GHOST_MODE_SECTION_HEADER"
            subtitle:@"GHOST_MODE_SUBTITLE" icon:@"eye.slash.fill"];
        if (row < 2) return nil;
        rows = self.ghostRows;
        row -= 2;
    } else if (section == FILE_FIXER && row == 0) {
        return [self rowWithKey:FILE_PICKER_FIX_KEY title:@"FIX_FILE_PICKER_TITLE"
            subtitle:@"FIX_FILE_PICKER_SUBTITLE" icon:@"folder.fill.badge.gear"];
    } else if (section == FAKE_LOCATION && row == 0) {
        return [self rowWithKey:FAKE_LOCATION_ENABLED_KEY title:@"ENABLE_FAKE_LOCATION_TITLE"
            subtitle:@"ENABLE_FAKE_LOCATION_SUBTITLE" icon:@"location.fill"];
    }
    return row >= 0 && row < (NSInteger)rows.count ? rows[row] : nil;
}
@end
