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
#import "UI/ProfileNavigation.h"
#define TGLoc(key) key

NSString *const kTGExtraGhostExceptionId = @"id";
static NSNumber *requestedId;
static id requestedSource;
static NSUInteger requests, opens, failures;
static void (^lookupCompletion)(TGExtraProfileOpener);
static void TGExtraShowToast(NSString *text) { failures++; }
@implementation TGExtraProfileNavigation
+ (void)loadProfileForPeerId:(NSNumber *)peerId fromNode:(id)node
                 completion:(void (^)(TGExtraProfileOpener))completion {
    requests++;
    requestedId = peerId;
    requestedSource = node;
    lookupCompletion = completion;
}
@end

@interface TGExtra : NSObject
@property(nonatomic, copy) void (^dismissalCompletion)(void);
@property(nonatomic, strong) id profileSourceNode;
@property(nonatomic) BOOL isOpeningGhostProfile;
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

static void checkProfile(NSDictionary *entry) {
    TGExtra *settings = [TGExtra new];
    settings.profileSourceNode = [NSObject new];
    NSUInteger previousRequests = requests, previousOpens = opens;
    [settings openProfileForException:entry];
    NSCAssert([requestedId isEqual:entry[@"id"]] && requestedSource == settings.profileSourceNode,
              @"Resolve only the stored ID in the actual source account");
    NSCAssert(!settings.dismissalCompletion, @"Keep settings open while loading the native profile");
    [settings openProfileForException:entry];
    NSCAssert(requests == previousRequests + 1, @"Repeated taps cannot start concurrent navigation");
    lookupCompletion(^BOOL { opens++; return YES; });
    NSCAssert(opens == previousOpens && settings.dismissalCompletion,
              @"Wait for settings to finish dismissing before navigating");
    settings.dismissalCompletion();
    NSCAssert(opens == previousOpens + 1, @"Invoke the prepared native action");
}

int main(void) {
    @autoreleasepool {
        checkProfile(@{@"id": @42});
        checkProfile(@{@"id": @42, @"username": @""});
        checkProfile(@{@"id": @7331000001LL, @"name": @"Test", @"customName": @"Friend"});
        checkProfile(@{@"id": @42, @"username": @"test_user"});
        checkProfile(@{@"id": @42, @"username": @"changed_username"});
        checkProfile(@{@"id": @43, @"username": @"test_user"});
        TGExtra *settings = [TGExtra new];
        [settings openProfileForException:@{@"id": @99}];
        lookupCompletion(nil);
        NSCAssert(failures == 1 && !settings.dismissalCompletion && !settings.isOpeningGhostProfile,
                  @"A missing profile leaves settings open and permits retrying");
        NSUInteger previousRequests = requests;
        [settings openProfileForException:@{@"id": @99}];
        NSCAssert(requests == previousRequests + 1, @"Retry after an unavailable profile");
        lookupCompletion(^BOOL { return NO; });
        settings.dismissalCompletion();
        NSCAssert(failures == 2, @"Report when the native handler cannot open a profile");
        puts("PASS ghost exceptions: stable ID, native action, source account, dismissal order, repeated taps and lookup failure");
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
