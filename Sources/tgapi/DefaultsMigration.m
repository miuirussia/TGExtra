#import "Constants.h"

void TGExtraMigrateDefaults(NSUserDefaults *defaults) {
    @autoreleasepool {
        if ([defaults boolForKey:@"TGExtraFeatureMigrationDone"]) return;
        if (![defaults objectForKey:kDisableAllAds]) {
            [defaults setBool:[defaults boolForKey:kDisableOnlineStatus] forKey:kDisableAllAds];
        }
        if (![defaults objectForKey:kGhostModeEnabled]) {
            BOOL enabled = NO;
            for (NSString *key in @[
                kDisableOnlineStatus, kDisableTypingStatus, kDisableRecordingVideoStatus,
                kDisableUploadingVideoStatus, kDisableRecordingVoiceStatus, kDisableUploadingVoiceStatus,
                kDisableUploadingPhotoStatus, kDisableUploadingFileStatus, kDisableChoosingLocationStatus,
                kDisableChoosingContactStatus, kDisablePlayingGameStatus, kDisableRecordingRoundVideoStatus,
                kDisableUploadingRoundVideoStatus, kDisableSpeakingInGroupCallStatus,
                kDisableChoosingStickerStatus, kDisableEmojiInteractionStatus, kDisableEmojiAcknowledgementStatus,
                kDisableMessageReadReceipt, kDisableStoriesReadReceipt
            ]) enabled |= [defaults boolForKey:key];
            [defaults setBool:enabled forKey:kGhostModeEnabled];
        }
        [defaults setBool:YES forKey:@"TGExtraFeatureMigrationDone"];
    }
}

#ifndef TGEXTRA_TESTING
__attribute__((constructor(101))) static void TGExtraRunDefaultsMigration(void) {
    TGExtraMigrateDefaults(NSUserDefaults.standardUserDefaults);
}
#endif
