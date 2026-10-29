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

# Exercise the language action with the real localization resolver and an in-memory defaults store.
language_source = (ROOT / 'Sources/tgapi/UI/LanguageSelector.m').read_text()
language_actions = language_source[language_source.index('- (void)closeTapped {'):language_source.rindex('@end')]
initial_selection = language_source[language_source.index('    self.initialLanguageCode ='):language_source.index('    // Hardcoded full list')]
localization_source = (ROOT / 'Sources/tgapi/UI/TGExtraLocalization.m').read_text()
localization_body = localization_source[localization_source.index('@interface TGExtraLocalization ()'):]

language_support = r'''
#import "EmbeddedLangs.h"
#define UIAlertActionStyleDestructive 2
@interface TGLocalization : NSObject
@property NSDictionary *strings;
- (instancetype)initWithVersion:(int)version code:(id)code dict:(id)dict isActive:(BOOL)active;
- (NSString *)get:(NSString *)key;
@end
@implementation TGLocalization
- (instancetype)initWithVersion:(int)version code:(id)code dict:(id)dict isActive:(BOOL)active {
    if ((self = [super init])) _strings = dict;
    return self;
}
- (NSString *)get:(NSString *)key { return self.strings[key] ?: key; }
@end
@interface TGExtraLocalization : NSObject
@property TGLocalization *localization;
@property(nonatomic, copy, readonly) NSString *languageCode;
+ (instancetype)shared;
+ (NSString *)localizedStringForKey:(NSString *)key;
@end
static NSString *TGExtraBundlePath(void) { return nil; }
'''

language_ui = r'''
@interface LanguageDefaults : NSUserDefaults
@property NSMutableDictionary *values;
@end
@implementation LanguageDefaults
- (instancetype)init { if ((self = [super init])) _values = [NSMutableDictionary new]; return self; }
- (id)objectForKey:(NSString *)key { return self.values[key]; }
- (NSString *)stringForKey:(NSString *)key { return self.values[key]; }
- (void)setObject:(id)value forKey:(NSString *)key { self.values[key] = value; }
- (void)removeObjectForKey:(NSString *)key { [self.values removeObjectForKey:key]; }
- (BOOL)synchronize { [events addObject:@"save"]; return NO; }
@end
@interface TableStub : NSObject
- (void)reloadData;
@end
@implementation TableStub
- (void)reloadData {}
@end
@interface TGExtra (Dismiss)
- (void)dismissViewControllerAnimated:(BOOL)animated completion:(id)completion;
@end
@implementation TGExtra (Dismiss)
- (void)dismissViewControllerAnimated:(BOOL)animated completion:(id)completion { [events addObject:@"dismiss"]; }
@end
@interface LanguageSelector : TGExtra
@property NSString *initialLanguageCode;
@property NSString *selectedLanguageCode;
@property TableStub *tableView;
- (void)configure;
- (void)applyTapped;
@end
@implementation LanguageSelector
'''

language_tests = r'''
@end
int main(int argc, const char **argv) { @autoreleasepool {
    events = [NSMutableArray new];
    LanguageDefaults *defaults = [LanguageDefaults new];
    Method defaultsMethod = class_getClassMethod(NSUserDefaults.class, @selector(standardUserDefaults));
    method_setImplementation(defaultsMethod, imp_implementationWithBlock(^id(id cls) { return defaults; }));
    NSString *device = @(argv[1]), *expected = @(argv[2]);
    Method preferred = class_getClassMethod(NSLocale.class, @selector(preferredLanguages));
    method_setImplementation(preferred, imp_implementationWithBlock(^id(id cls) { return @[device]; }));
    if (argc > 3) [defaults setObject:@(argv[3]) forKey:@"TGExtraLanguage"];
    NSCAssert([TGExtraLocalization.shared.languageCode isEqual:expected], @"Resolve the actual default/explicit language");
    LanguageSelector *selector = [LanguageSelector new];
    [selector configure];
    NSCAssert([selector.initialLanguageCode isEqual:expected] && [selector.selectedLanguageCode isEqual:expected], @"Mark the language actually displayed");
    [selector applyTapped];
    NSCAssert([events isEqual:@[@"dismiss"]], @"Unchanged language does not restart");
    [events removeAllObjects];
    NSString *chosen = [expected isEqual:@"en"] ? @"ru" : @"en";
    selector.selectedLanguageCode = chosen;
    [selector applyTapped];
    NSCAssert(events.count == 0 && selector.alert.actions.count == 2, @"Changing the automatic language requires confirmation");
    UIAlertAction *cancel = selector.alert.actions.lastObject;
    cancel.handler(cancel);
    NSCAssert([selector.selectedLanguageCode isEqual:expected], @"Cancel restores selection");
    [events removeAllObjects];
    id previous = [defaults objectForKey:@"TGExtraLanguage"];
    selector.selectedLanguageCode = chosen;
    [selector applyTapped];
    fileSaveSucceeds = NO;
    UIAlertAction *confirm = selector.alert.actions.firstObject;
    confirm.handler(confirm);
    NSArray *failed = @[@"file", [TGExtraLocalization localizedStringForKey:@"SETTINGS_SAVE_FAILED"]];
    NSCAssert([events isEqual:failed], @"A failed save reports failure without suspend/exit");
    NSCAssert([[defaults objectForKey:@"TGExtraLanguage"] isEqual:previous] || (!previous && ![defaults objectForKey:@"TGExtraLanguage"]), @"Failure preserves the old preference, including its absence");
    [events removeAllObjects];
    fileSaveSucceeds = YES;
    [selector applyTapped];
    confirm = selector.alert.actions.firstObject;
    confirm.handler(confirm);
    NSArray *saved = @[@"file", @"save", @"suspend", @"exit"];
    NSCAssert([events isEqual:saved] && [[defaults stringForKey:@"TGExtraLanguage"] isEqual:chosen], @"Persist selection before restarting even if CFPreferences sync fails");
    puts("PASS actual language selection, automatic/explicit fallback, cancellation, save failure rollback and restart ordering");
} return 0; }
'''

with tempfile.TemporaryDirectory(prefix='tgextra-language-') as tmp:
    path = Path(tmp)
    harness = path / 'language.m'
    harness.write_text(support + apply_changes + '\n@end\n' + language_support + localization_body + language_ui
                       + '- (void)configure {\n' + initial_selection + '}\n' + language_actions + language_tests)
    binary = path / 'language-tests'
    subprocess.run(['clang', '-fobjc-arc', '-Werror', '-framework', 'Foundation',
                    '-I' + str(ROOT / 'Sources/tgapi'), '-I' + str(ROOT / 'Sources/tgapi/UI'),
                    str(harness), '-o', str(binary)], check=True)
    for arguments in [('ru-RU', 'ru'), ('zh-Hant-TW', 'tw'), ('de-DE', 'en'), ('ru-RU', 'en', 'en'), ('en-US', 'en', 'unknown')]:
        subprocess.run([str(binary), *arguments], check=True)
