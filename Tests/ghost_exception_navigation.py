#!/usr/bin/env python3
"""Exercise the production exception action and its dismissal completion."""
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parent.parent
source = (ROOT / 'Sources/tgapi/UI/GhostExceptionsSection.m').read_text()
action = source[source.index('- (void)openProfileForException:'):source.rindex('@end')]

support = r'''
#import <Foundation/Foundation.h>
#import "GhostExceptions.h"

NSString *const kTGExtraGhostExceptionId = @"id";
NSString *const kTGExtraGhostExceptionUsername = @"username";
static NSURL *openedURL;
static void TGExtraOpenTelegramURL(NSURL *url) { openedURL = url; }

@interface TGExtra : NSObject
@property(nonatomic, copy) void (^dismissalCompletion)(void);
- (void)dismissViewControllerAnimated:(BOOL)animated completion:(void (^)(void))completion;
- (void)openProfileForException:(NSDictionary *)entry;
@end
@implementation TGExtra
- (void)dismissViewControllerAnimated:(BOOL)animated completion:(void (^)(void))completion {
    NSCAssert(animated, @"Preserve animated dismissal");
    self.dismissalCompletion = completion;
}
'''

tests = r'''
@end

static void checkProfile(NSDictionary *entry, NSString *expected) {
    TGExtra *settings = [TGExtra new];
    openedURL = nil;
    [settings openProfileForException:entry];
    NSCAssert(!openedURL && settings.dismissalCompletion,
              @"Wait for settings to finish dismissing before navigating");
    settings.dismissalCompletion();
    NSCAssert([openedURL.absoluteString isEqualToString:expected],
              @"Unexpected profile URL: %@", openedURL);
}

int main(void) {
    @autoreleasepool {
        checkProfile(@{@"id": @42}, @"tg://user?id=42");
        checkProfile(@{@"id": @42, @"username": @""}, @"tg://user?id=42");
        checkProfile(@{@"id": @7331000001LL, @"name": @"Test", @"customName": @"Friend"},
                     @"tg://user?id=7331000001");
        checkProfile(@{@"id": @42, @"username": @"test_user"},
                     @"tg://resolve?domain=test_user&profile");
        puts("PASS ghost exception profiles: ID only, empty username, 64-bit ID, username and dismissal order");
    }
    return 0;
}
'''

with tempfile.TemporaryDirectory(prefix='tgextra-ghost-navigation-') as tmp:
    harness = Path(tmp) / 'navigation.m'
    harness.write_text(support + action + tests)
    binary = Path(tmp) / 'navigation'
    subprocess.run([
        'xcrun', 'clang', '-fobjc-arc', '-Werror', '-framework', 'Foundation',
        '-I', str(ROOT / 'Sources/tgapi'), str(harness), '-o', str(binary),
    ], check=True)
    subprocess.run([str(binary)], check=True)
