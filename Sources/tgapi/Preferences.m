#import "Constants.h"

static NSArray<NSString *> *TGExtraPreferenceKeys(void) {
    return @[
        kGhostModeEnabled, kGhostDetailsToggle,
        kDisableOnlineStatus, kDisableTypingStatus, kDisableRecordingVideoStatus,
        kDisableUploadingVideoStatus, kDisableRecordingVoiceStatus, kDisableUploadingVoiceStatus,
        kDisableUploadingPhotoStatus, kDisableUploadingFileStatus, kDisableChoosingLocationStatus,
        kDisableChoosingContactStatus, kDisablePlayingGameStatus, kDisableRecordingRoundVideoStatus,
        kDisableUploadingRoundVideoStatus, kDisableSpeakingInGroupCallStatus,
        kDisableChoosingStickerStatus, kDisableEmojiInteractionStatus, kDisableEmojiAcknowledgementStatus,
        kDisableMessageReadReceipt, kDisableReactionReadReceipt, kDisableMentionReadReceipt,
        kDisableStoriesReadReceipt, kDisableScreenshotNotification,
        kDisableAllAds, kDisableForwardRestriction, kIgnorePrivateChatCopyProtection,
        kDisableDoubleTapReactions, kHideRecordingButton, kForceTLottie,
        kAntiRevoke, kAntiEdit, kAntiSelfDestruct, kAntiAutoDelete,
        kVideoToVoice, kHideDisappearingLabel,
        FILE_PICKER_FIX_KEY, FAKE_LOCATION_ENABLED_KEY, FAKE_LATITUDE_KEY, FAKE_LONGITUDE_KEY,
        kGhostExceptions, @"TGExtraLanguage", @"TGExtraFeatureMigrationDone"
    ];
}

static NSURL *TGExtraPreferencesURL(void) {
#ifdef TGEXTRA_TESTING
    NSString *path = NSProcessInfo.processInfo.environment[@"TGEXTRA_TEST_PREFERENCES_PATH"];
    return path.length ? [NSURL fileURLWithPath:path] : nil;
#else
    return [NSURL fileURLWithPath:[NSHomeDirectory()
        stringByAppendingPathComponent:@"Library/Application Support/TGExtra/Preferences.plist"]];
#endif
}

BOOL TGExtraSavePreferences(void) {
    NSURL *url = TGExtraPreferencesURL();
    if (!url) return YES;
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    @synchronized(defaults) {
        NSMutableDictionary *settings = [NSMutableDictionary new];
        for (NSString *key in TGExtraPreferenceKeys()) {
            id value = [defaults objectForKey:key];
            if (value != nil) settings[key] = value;
        }
        NSError *error = nil;
        NSData *data = [NSPropertyListSerialization dataWithPropertyList:settings
            format:NSPropertyListBinaryFormat_v1_0 options:0 error:&error];
        BOOL saved = data != nil && [NSFileManager.defaultManager
            createDirectoryAtURL:url.URLByDeletingLastPathComponent
            withIntermediateDirectories:YES attributes:nil error:&error] &&
            [data writeToURL:url options:NSDataWritingAtomic error:&error];
        if (!saved) NSLog(@"[TGExtra] Could not save preferences: %@", error);
        return saved;
    }
}

void TGExtraRestorePreferences(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSURL *url = TGExtraPreferencesURL();
        if (!url) return;
        NSDictionary *settings = [NSDictionary dictionaryWithContentsOfURL:url];
        NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
        for (NSString *key in TGExtraPreferenceKeys()) {
            id value = settings[key];
            if (value != nil) [defaults setObject:value forKey:key];
        }
    });
}
