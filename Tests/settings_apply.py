#!/usr/bin/env python3
"""Exercise the real Apply action without suspending or terminating the test process."""
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parent.parent
source = (ROOT / 'Sources/tgapi/UI/TGExtra.m').read_text()
apply_changes = source[source.index('- (void)applyChanges {'):source.index('- (UIColor *)dynamicColorBW {')]

support = r'''
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import "Constants.h"
#define TGLoc(key) key
#define UIAlertControllerStyleAlert 0
#define UIAlertActionStyleDefault 0
#define UIAlertActionStyleCancel 1
static NSMutableArray *events;
static BOOL fileSaveSucceeds = YES;
BOOL TGExtraSavePreferences(void) {
    [events addObject:@"file"];
    return fileSaveSucceeds;
}
static void TGExtraShowToast(NSString *message) { [events addObject:message]; }

@interface BufferedDefaults : NSUserDefaults
@property BOOL pendingHidden;
@property BOOL savedHidden;
@property BOOL syncSucceeds;
@end
@implementation BufferedDefaults
- (BOOL)boolForKey:(NSString *)key { return self.pendingHidden; }
- (void)setBool:(BOOL)value forKey:(NSString *)key { self.pendingHidden = value; }
- (BOOL)synchronize {
    [events addObject:@"save"];
    if (self.syncSucceeds) self.savedHidden = self.pendingHidden;
    return self.syncSucceeds;
}
@end

@interface UIAlertAction : NSObject
@property NSInteger style;
@property (copy) void (^handler)(UIAlertAction *);
+ (instancetype)actionWithTitle:(NSString *)title style:(NSInteger)style handler:(void (^)(UIAlertAction *))handler;
@end
@implementation UIAlertAction
+ (instancetype)actionWithTitle:(NSString *)title style:(NSInteger)style handler:(void (^)(UIAlertAction *))handler {
    UIAlertAction *action = [self new];
    action.style = style;
    action.handler = handler;
    return action;
}
@end

@interface UIAlertController : NSObject
@property NSMutableArray<UIAlertAction *> *actions;
+ (instancetype)alertControllerWithTitle:(NSString *)title message:(NSString *)message preferredStyle:(NSInteger)style;
- (void)addAction:(UIAlertAction *)action;
@end
@implementation UIAlertController
+ (instancetype)alertControllerWithTitle:(NSString *)title message:(NSString *)message preferredStyle:(NSInteger)style {
    UIAlertController *alert = [self new];
    alert.actions = [NSMutableArray new];
    return alert;
}
- (void)addAction:(UIAlertAction *)action { [self.actions addObject:action]; }
@end

@interface UIApplication : NSObject
+ (instancetype)sharedApplication;
- (void)suspend;
@end
@implementation UIApplication
+ (instancetype)sharedApplication { return [self new]; }
- (void)suspend { [events addObject:@"suspend"]; }
@end

static void testExit(int status) {
    NSCAssert(status == 0, @"Apply closes normally");
    [events addObject:@"exit"];
}
static void testDispatchAfter(dispatch_time_t when, dispatch_queue_t queue, dispatch_block_t block) { block(); }
#define exit testExit
#define dispatch_after testDispatchAfter

@interface TGExtra : NSObject
@property UIAlertController *alert;
- (void)applyChanges;
- (void)presentViewController:(UIAlertController *)alert animated:(BOOL)animated completion:(id)completion;
@end
@implementation TGExtra
- (void)presentViewController:(UIAlertController *)alert animated:(BOOL)animated completion:(id)completion { self.alert = alert; }
'''

tests = r'''
@end
int main(void) {
    @autoreleasepool {
        events = [NSMutableArray new];
        BufferedDefaults *defaults = [BufferedDefaults new];
        Method method = class_getClassMethod(NSUserDefaults.class, @selector(standardUserDefaults));
        IMP original = method_setImplementation(method, imp_implementationWithBlock(^id(id cls) { return defaults; }));
        for (NSNumber *hidden in @[@NO, @YES]) {
          for (NSNumber *sync in @[@NO, @YES]) {
            defaults.syncSucceeds = sync.boolValue;
            defaults.savedHidden = !hidden.boolValue;
            [defaults setBool:hidden.boolValue forKey:kDisableOnlineStatus];
            TGExtra *menu = [TGExtra new];
            [menu applyChanges];
            NSCAssert(events.count == 0, @"Opening the confirmation must not close the app");
            UIAlertAction *cancel = menu.alert.actions.lastObject;
            NSCAssert(cancel.style == UIAlertActionStyleCancel, @"Keep the cancel action");
            if (cancel.handler) cancel.handler(cancel);
            NSCAssert(events.count == 0, @"Cancelling must not suspend or terminate the app");
            [menu applyChanges];
            UIAlertAction *confirm = menu.alert.actions.firstObject;
            confirm.handler(confirm);
            NSArray *expected = @[@"file", @"save", @"suspend", @"exit"];
            NSCAssert([events isEqual:expected], @"Save the independent preferences file before suspending and exiting: %@", events);
            [events removeAllObjects];
          }
        }
        fileSaveSucceeds = NO;
        TGExtra *menu = [TGExtra new];
        [menu applyChanges];
        UIAlertAction *confirm = menu.alert.actions.firstObject;
        confirm.handler(confirm);
        NSArray *failedSave = @[@"file", @"SETTINGS_SAVE_FAILED"];
        NSCAssert([events isEqual:failedSave], @"A failed file write must report failure and keep the app open: %@", events);
        method_setImplementation(method, original);
        puts("PASS Apply writes the preferences file before exit even when defaults sync fails; cancellation and file errors keep the app running");
    }
    return 0;
}
'''

with tempfile.TemporaryDirectory(prefix='tgextra-apply-') as tmp:
    path = Path(tmp)
    harness = path / 'apply.m'
    harness.write_text(support + apply_changes + tests)
    binary = path / 'apply-tests'
    subprocess.run(['clang', '-fobjc-arc', '-Werror', '-framework', 'Foundation',
                    '-I' + str(ROOT / 'Sources/tgapi'), str(harness), '-o', str(binary)], check=True)
    subprocess.run([str(binary)], check=True)
