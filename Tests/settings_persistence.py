#!/usr/bin/env python3
"""Verify preferences across real process exits even when defaults never persist."""
import os
from pathlib import Path
import plistlib
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parent.parent
HARNESS = r'''
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import "Constants.h"

// Model a host that returns stale defaults on every new launch, regardless of sync.
@interface NonpersistentDefaults : NSUserDefaults
@property NSMutableDictionary *values;
@end
@implementation NonpersistentDefaults
- (instancetype)init {
    if ((self = [super init])) {
        _values = [@{kDisableOnlineStatus: @YES, kIgnorePrivateChatCopyProtection: @NO,
                     kGhostModeEnabled: @YES, kDisableTypingStatus: @YES,
                     @"TGExtraFeatureMigrationDone": @YES, @"HostSetting": @"keep",
                     @"TGExtraEditHistory": @{@"keep": @YES}} mutableCopy];
    }
    return self;
}
- (id)objectForKey:(NSString *)key { return self.values[key]; }
- (BOOL)boolForKey:(NSString *)key { return [[self objectForKey:key] boolValue]; }
- (void)setObject:(id)value forKey:(NSString *)key { self.values[key] = value; }
- (void)setBool:(BOOL)value forKey:(NSString *)key { [self setObject:@(value) forKey:key]; }
- (BOOL)synchronize { return YES; } // Success does not guarantee the next launch's state.
@end

void TGExtraMigrateDefaults(NSUserDefaults *defaults);
int main(int argc, const char **argv) {
    @autoreleasepool {
        NSCAssert(argc == 3, @"mode and expected online state required");
        NonpersistentDefaults *defaults = [NonpersistentDefaults new];
        Method method = class_getClassMethod(NSUserDefaults.class, @selector(standardUserDefaults));
        method_setImplementation(method, imp_implementationWithBlock(^id(id cls) { return defaults; }));
        NSString *mode = @(argv[1]);
        BOOL hidden = atoi(argv[2]) != 0;
        if ([mode isEqual:@"write"] || [mode isEqual:@"fail"]) {
            [defaults setBool:hidden forKey:kDisableOnlineStatus];
            [defaults setBool:!hidden forKey:kIgnorePrivateChatCopyProtection];
            [defaults setBool:hidden forKey:kDisableDoubleTapReactions];
            [defaults setBool:hidden forKey:kForceTLottie];
            [defaults setBool:hidden forKey:kHideRecordingButton];
            [defaults setBool:hidden forKey:kVideoToVoice];
            [defaults setBool:NO forKey:kGhostModeEnabled];
            [defaults setObject:@"ru" forKey:@"TGExtraLanguage"];
            [defaults setObject:@12.34 forKey:FAKE_LATITUDE_KEY];
            [defaults setObject:@[@{@"id": @42, @"name": @"Test"}] forKey:kGhostExceptions];
            BOOL saved = TGExtraSavePreferences();
            NSCAssert(saved == [mode isEqual:@"write"], @"Report the actual file-write result");
            [defaults synchronize];
        } else if ([mode isEqual:@"read"]) {
            TGExtraRestorePreferences();
            TGExtraMigrateDefaults(defaults);
            NSCAssert([defaults boolForKey:kDisableOnlineStatus] == hidden, @"Restore an explicit online-status value");
            NSCAssert([defaults boolForKey:kIgnorePrivateChatCopyProtection] == !hidden, @"Restore the private-chat copy option");
            NSCAssert([defaults boolForKey:kDisableDoubleTapReactions] == hidden, @"Restore the double-tap reaction option");
            NSCAssert([defaults boolForKey:kForceTLottie] == hidden, @"Restore the forced tlottie option");
            NSCAssert([defaults boolForKey:kHideRecordingButton] == hidden, @"Restore recording button removal");
            NSCAssert([defaults boolForKey:kVideoToVoice] == hidden, @"Restore the video-to-voice checkbox");
            NSCAssert(![defaults boolForKey:kGhostModeEnabled], @"False must override stale true defaults despite enabled subfeatures");
            NSCAssert([[defaults objectForKey:@"TGExtraLanguage"] isEqual:@"ru"], @"Preserve the selected language");
            NSCAssert([[defaults objectForKey:FAKE_LATITUDE_KEY] isEqual:@12.34], @"Preserve coordinates");
            NSCAssert([[defaults objectForKey:kGhostExceptions] count] == 1, @"Preserve exceptions");
            [defaults setBool:!hidden forKey:kDisableOnlineStatus];
            TGExtraRestorePreferences();
            NSCAssert([defaults boolForKey:kDisableOnlineStatus] == !hidden, @"Restoration only runs once, never overwriting live changes");
        } else {
            TGExtraRestorePreferences();
            NSCAssert([defaults boolForKey:kDisableOnlineStatus], @"Missing or corrupt files preserve legacy settings");
            NSCAssert(![defaults boolForKey:kIgnorePrivateChatCopyProtection], @"A fresh install keeps the private-chat copy option off");
            NSCAssert(![defaults boolForKey:kDisableDoubleTapReactions], @"A fresh install keeps double-tap reactions enabled");
            NSCAssert(![defaults boolForKey:kForceTLottie], @"A fresh install keeps the client's renderer selection");
            NSCAssert(![defaults boolForKey:kHideRecordingButton], @"Recording button removal defaults off");
            NSCAssert(![defaults boolForKey:kVideoToVoice], @"Video to voice defaults off");
        }
        NSCAssert([[defaults objectForKey:@"HostSetting"] isEqual:@"keep"], @"Never restore the host app's settings");
        NSCAssert([[defaults objectForKey:@"TGExtraEditHistory"] isEqual:@{@"keep": @YES}], @"Never restore message data with settings");
    }
    return 0;
}
'''

with tempfile.TemporaryDirectory(prefix='tgextra-persistence-') as tmp:
    work = Path(tmp)
    harness = work / 'main.m'
    harness.write_text(HARNESS)
    binary = work / 'persistence-tests'
    subprocess.run(['clang', '-fobjc-arc', '-Werror', '-DTGEXTRA_TESTING',
                    '-framework', 'Foundation', '-I' + str(ROOT / 'Sources/tgapi'),
                    str(harness), str(ROOT / 'Sources/tgapi/Preferences.m'),
                    str(ROOT / 'Sources/tgapi/DefaultsMigration.m'), '-o', str(binary)], check=True)
    settings = work / 'container/Library/Application Support/TGExtra/Preferences.plist'
    env = dict(os.environ, TGEXTRA_TEST_PREFERENCES_PATH=str(settings))

    def run(mode, hidden=False, environment=env):
        subprocess.run([str(binary), mode, str(int(hidden))], env=environment, check=True)

    run('legacy')
    for hidden in (False, True, False):
        run('write', hidden)
        saved = plistlib.loads(settings.read_bytes())
        assert saved['disableOnlineStatus'] == hidden
        assert saved['TGExtraIgnorePrivateChatCopyProtection'] == (not hidden)
        assert saved['TGExtraDisableDoubleTapReactions'] == hidden
        assert saved['TGExtraForceTLottie'] == hidden
        assert saved['TGExtraHideRecordingButton'] == hidden
        assert saved['TGExtraVideoToVoice'] == hidden
        assert 'HostSetting' not in saved and 'TGExtraEditHistory' not in saved
        # Even an unexpected field in the file cannot overwrite unrelated defaults.
        saved.update(HostSetting='replace', TGExtraEditHistory={})
        settings.write_bytes(plistlib.dumps(saved))
        run('read', hidden)

    previous = settings.read_bytes()
    blocker = work / 'not-a-directory'
    blocker.write_text('keep')
    run('fail', environment=dict(env, TGEXTRA_TEST_PREFERENCES_PATH=str(blocker / 'Preferences.plist')))
    assert settings.read_bytes() == previous, 'A failed save must not damage the last snapshot'
    assert blocker.read_text() == 'keep'
    settings.write_text('not a property list')
    run('legacy')

print('PASS real-process settings persistence: online off/on/off, private-copy on/off/on, legacy fallback, false values, isolation and failed writes')
