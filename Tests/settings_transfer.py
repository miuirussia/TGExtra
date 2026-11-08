#!/usr/bin/env python3
"""Exercise settings validation, round trips, exception reload and rollback."""
from pathlib import Path
import os
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parent.parent
HARNESS = r'''
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import "Constants.h"
#import "GhostExceptions.h"

static NSData *payload(NSDictionary *values, id version) {
    return [NSJSONSerialization dataWithJSONObject:@{@"format": @"TGExtra.settings", @"version": version, @"values": values} options:0 error:NULL];
}
int main(int argc, char **argv) { @autoreleasepool {
    NSUserDefaults *defaults = [[NSUserDefaults alloc] initWithSuiteName:NSUUID.UUID.UUIDString];
    Method standard = class_getClassMethod(NSUserDefaults.class, @selector(standardUserDefaults));
    method_setImplementation(standard, imp_implementationWithBlock(^id(id cls) { return defaults; }));
    [defaults setObject:@"keep" forKey:@"HostSetting"];
    [defaults setBool:YES forKey:kGhostReadOnReply];
    [defaults setBool:NO forKey:kGhostKeepVoiceUnread];
    [defaults setObject:@[@{@"id": @42, @"name": @"Old", @"customName": @"Friend"}] forKey:kGhostExceptions];
    NSCAssert([TGExtraGhostExceptions containsPeerId:42], @"Warm the exception cache");
    NSError *error = nil;
    NSData *exported = TGExtraExportSettings(&error);
    NSDictionary *values = TGExtraValidateSettings(exported, &error);
    NSCAssert(values && [values[kGhostReadOnReply] boolValue] && ![values[kGhostKeepVoiceUnread] boolValue], @"Round trip true and false settings");
    NSCAssert(values[@"HostSetting"] == nil && values[@"TGExtraFeatureMigrationDone"] == nil, @"Export contains only transferable preferences");
    NSCAssert([values[kGhostExceptions][0][@"customName"] isEqual:@"Friend"], @"Preserve custom exception labels");
    NSDictionary *bad[] = {
        @{kGhostReadOnReply: @1}, @{kGhostReadOnReply: @"true"}, @{kGhostExceptions: @"bad"},
        @{FAKE_LATITUDE_KEY: @91}, @{FAKE_LONGITUDE_KEY: @181}, @{FAKE_LATITUDE_KEY: @YES},
        @{@"TGExtraLanguage": @"unknown"}, @{kGhostExceptions: @[@{@"id": @YES}]},
        @{kGhostExceptions: @[@{@"id": @42}, @{@"id": @42}]}, @{kGhostExceptions: @[@{@"id": @42, @"customName": @1}]}
    };
    for (NSUInteger i = 0; i < sizeof(bad) / sizeof(*bad); i++) {
        error = nil;
        NSCAssert(TGExtraValidateSettings(payload(bad[i], @1), &error) == nil && error, @"Reject invalid types and ranges before modifying settings");
    }
    for (id version in @[@YES, @0, @2, @1.5, @"1"]) NSCAssert(TGExtraValidateSettings(payload(@{kGhostReadOnReply: @YES}, version), NULL) == nil, @"Validate the exact format version");
    NSCAssert(TGExtraValidateSettings(payload(@{@"HostSetting": @"replace"}, @1), NULL) == nil, @"Reject files with no supported keys");
    NSData *incoming = payload(@{kGhostReadOnReply: @NO, kGhostKeepVoiceUnread: @YES,
        kGhostExceptions: @[@{@"id": @43, @"name": @"New"}], @"HostSetting": @"replace"}, @1);
    BOOL expectFailure = argc > 1;
    NSCAssert(TGExtraImportSettings(incoming, &error) == !expectFailure, @"Report the persistent save result");
    NSCAssert([defaults boolForKey:kGhostReadOnReply] == expectFailure && [defaults boolForKey:kGhostKeepVoiceUnread] == !expectFailure, @"Apply settings atomically or roll back on failure");
    NSCAssert([TGExtraGhostExceptions containsPeerId:42] == expectFailure && [TGExtraGhostExceptions containsPeerId:43] == !expectFailure, @"Reload live exceptions after successful imports only");
    NSCAssert([[defaults objectForKey:@"HostSetting"] isEqual:@"keep"], @"Never overwrite host settings");
    puts("PASS settings transfer validation, booleans, coordinates, custom labels, isolation, exception reload and save rollback");
} return 0; }
'''
with tempfile.TemporaryDirectory(prefix='tgextra-settings-transfer-') as tmp:
    work = Path(tmp)
    main = work / 'main.m'
    main.write_text(HARNESS)
    binary = work / 'tests'
    subprocess.run(['clang', '-fobjc-arc', '-Werror', '-DTGEXTRA_TESTING', '-framework', 'Foundation',
                    '-I' + str(ROOT / 'Sources/tgapi'), str(main),
                    str(ROOT / 'Sources/tgapi/Preferences.m'), str(ROOT / 'Sources/tgapi/GhostExceptions.m'), '-o', str(binary)], check=True)
    subprocess.run([str(binary)], env=dict(os.environ, TGEXTRA_TEST_PREFERENCES_PATH=str(work / 'settings.plist')), check=True)
    blocker = work / 'blocker'
    blocker.write_text('keep')
    subprocess.run([str(binary), 'failure'], env=dict(os.environ, TGEXTRA_TEST_PREFERENCES_PATH=str(blocker / 'settings.plist')), check=True)
