#import "Constants.h"
#import <math.h>

static NSArray<NSString *> *TGExtraPreferenceKeys(void) {
    return @[
        kGhostModeEnabled, kGhostDetailsToggle, kForceProfileServerLookup,
        kGhostReadOnReply, kGhostKeepVoiceUnread, kSaveDeletedStories, kAudioToVoice, kForwardDropAuthor,
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
        kVideoToVoice, kVideoToRound, kHideDisappearingLabel,
        FILE_PICKER_FIX_KEY, FAKE_LOCATION_ENABLED_KEY, FAKE_LATITUDE_KEY, FAKE_LONGITUDE_KEY,
        kGhostExceptions, @"TGExtraLanguage", @"TGExtraFeatureMigrationDone"
    ];
}

static NSArray<NSString *> *TGExtraTransferKeys(void) {
    NSMutableArray *keys = [TGExtraPreferenceKeys() mutableCopy];
    [keys removeObject:@"TGExtraFeatureMigrationDone"];
    [keys removeObject:kGhostDetailsToggle];
    [keys removeObject:kForceProfileServerLookup];
    return keys;
}

static BOOL transferError(NSError **error, NSString *message) {
    if (error) *error = [NSError errorWithDomain:@"TGExtraSettings" code:1
        userInfo:@{NSLocalizedDescriptionKey: message}];
    return NO;
}

NSData *TGExtraExportSettings(NSError **error) {
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    NSMutableDictionary *values = [NSMutableDictionary new];
    @synchronized(defaults) {
        for (NSString *key in TGExtraTransferKeys()) {
            id value = [defaults objectForKey:key];
            if (!value) {
                if ([key isEqual:@"TGExtraLanguage"]) continue;
                else if ([key isEqual:kGhostExceptions]) value = @[];
                else if ([key isEqual:FAKE_LATITUDE_KEY] || [key isEqual:FAKE_LONGITUDE_KEY]) value = @0;
                else value = @NO;
            }
            values[key] = value;
        }
    }
    return [NSJSONSerialization dataWithJSONObject:@{@"format": @"TGExtra.settings", @"version": @1, @"values": values}
        options:NSJSONWritingPrettyPrinted | NSJSONWritingSortedKeys error:error];
}

NSDictionary<NSString *, id> *TGExtraValidateSettings(NSData *data, NSError **error) {
    if (data.length == 0 || data.length > 1024 * 1024) {
        transferError(error, @"Invalid settings file size"); return nil;
    }
    id json = [NSJSONSerialization JSONObjectWithData:data options:0 error:error];
    if (![json isKindOfClass:NSDictionary.class] || ![json[@"format"] isEqual:@"TGExtra.settings"] ||
        ![json[@"version"] isKindOfClass:NSNumber.class] || CFGetTypeID((__bridge CFTypeRef)json[@"version"]) == CFBooleanGetTypeID() ||
        [json[@"version"] doubleValue] != 1 ||
        ![json[@"values"] isKindOfClass:NSDictionary.class]) {
        transferError(error, @"Unsupported TGExtra settings file"); return nil;
    }
    NSDictionary *source = json[@"values"];
    NSMutableDictionary *values = [NSMutableDictionary new];
    for (NSString *key in TGExtraTransferKeys()) {
        id value = source[key];
        if (!value) continue;
        BOOL valid = NO;
        if ([key isEqual:@"TGExtraLanguage"]) {
            valid = [value isKindOfClass:NSString.class] &&
                [@[@"ar", @"cn", @"en", @"es", @"fr", @"it", @"ja", @"ru", @"tw", @"vn"] containsObject:value];
        } else if ([key isEqual:FAKE_LATITUDE_KEY] || [key isEqual:FAKE_LONGITUDE_KEY]) {
            double limit = [key isEqual:FAKE_LATITUDE_KEY] ? 90 : 180;
            valid = [value isKindOfClass:NSNumber.class] && CFGetTypeID((__bridge CFTypeRef)value) != CFBooleanGetTypeID() &&
                isfinite([value doubleValue]) && fabs([value doubleValue]) <= limit;
        } else if ([key isEqual:kGhostExceptions]) {
            valid = [value isKindOfClass:NSArray.class] && [value count] <= 1000;
            NSMutableSet *ids = [NSMutableSet new];
            if (valid) for (id entry in value) {
                if (![entry isKindOfClass:NSDictionary.class]) { valid = NO; break; }
                NSNumber *peer = entry[@"id"];
                if (![peer isKindOfClass:NSNumber.class] || CFGetTypeID((__bridge CFTypeRef)peer) == CFBooleanGetTypeID() ||
                    peer.longLongValue <= 0 || peer.doubleValue != (double)peer.longLongValue || [ids containsObject:peer]) { valid = NO; break; }
                [ids addObject:peer];
                for (id name in entry) {
                    if (![name isKindOfClass:NSString.class] || ![@[@"id", @"name", @"username", @"customName"] containsObject:name] ||
                        (![name isEqual:@"id"] && (![entry[name] isKindOfClass:NSString.class] || [entry[name] length] > 512))) { valid = NO; break; }
                }
                if (!valid) break;
            }
        } else {
            valid = [value isKindOfClass:NSNumber.class] && CFGetTypeID((__bridge CFTypeRef)value) == CFBooleanGetTypeID();
        }
        if (!valid) { transferError(error, [@"Invalid setting: " stringByAppendingString:key]); return nil; }
        values[key] = value;
    }
    if (!values.count) { transferError(error, @"No supported settings in the file"); return nil; }
    return values;
}

BOOL TGExtraImportSettings(NSData *data, NSError **error) {
    NSDictionary *values = TGExtraValidateSettings(data, error);
    if (!values) return NO;
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    @synchronized(defaults) {
        NSMutableDictionary *previous = [NSMutableDictionary new];
        for (NSString *key in values) {
            previous[key] = [defaults objectForKey:key] ?: NSNull.null;
            [defaults setObject:values[key] forKey:key];
        }
        if (!TGExtraSavePreferences()) {
            for (NSString *key in previous) {
                if (previous[key] == NSNull.null) [defaults removeObjectForKey:key];
                else [defaults setObject:previous[key] forKey:key];
            }
            return transferError(error, @"Could not save imported settings");
        }
    }
    [NSNotificationCenter.defaultCenter postNotificationName:@"TGExtraSettingsImported" object:nil];
    return YES;
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
