#!/usr/bin/env python3
"""Exercise the production force-cleanup confirmation with real UIKit."""
from pathlib import Path
import platform
import subprocess
import tempfile

root = Path(__file__).resolve().parent.parent
sdk = Path(subprocess.check_output(['xcrun', '--sdk', 'macosx', '--show-sdk-path'], text=True).strip())
frameworks = sdk / 'System/iOSSupport/System/Library/Frameworks'
if not (frameworks / 'UIKit.framework/Headers/UIKit.h').exists():
    print('SKIP cleanup confirmation: Mac Catalyst SDK unavailable')
    raise SystemExit(0)
source = (root / 'Sources/tgapi/UI/SettingsMaintenance.m').read_text()
source = source[source.index('- (void)confirmClearTemporaryFiles {'):source.index('- (void)confirmClearMessageData {')]
source = source.replace('[UIAlertAction actionWithTitle:', '[TestAction actionWithTitle:')
support = r'''
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import "TemporaryFiles.h"
enum { MESSAGE_DATA = 8, FILE_FIXER = 7 };
static NSString *toast;
static void TGExtraShowToast(NSString *text) { toast = text; }
static NSString *TGLoc(NSString *key) {
    return [key isEqual:@"TEMPORARY_FILES_USAGE"] ? @"Files: %lu\nSize: %@" : key;
}
static void (^usageCallback)(NSUInteger, unsigned long long, NSError *);
static void (^clearCallback)(NSError *);
static NSUInteger measurements, deletions;
@implementation TGExtraTemporaryFiles
+ (void)didCopyFromURL:(NSURL *)source toURL:(NSURL *)destination {}
+ (void)removeAbandonedExports {}
+ (void)usageWithCompletion:(void (^)(NSUInteger, unsigned long long, NSError *))completion {
    measurements++;
    usageCallback = completion;
}
+ (void)clearWithCompletion:(void (^)(NSError *))completion {
    deletions++;
    clearCallback = completion;
}
@end
static char handlerKey;
@interface TestAction : NSObject
+ (UIAlertAction *)actionWithTitle:(NSString *)title style:(UIAlertActionStyle)style handler:(void (^)(UIAlertAction *))handler;
@end
@implementation TestAction
+ (UIAlertAction *)actionWithTitle:(NSString *)title style:(UIAlertActionStyle)style handler:(void (^)(UIAlertAction *))handler {
    UIAlertAction *action = [UIAlertAction actionWithTitle:title style:style handler:handler];
    objc_setAssociatedObject(action, &handlerKey, handler, OBJC_ASSOCIATION_COPY_NONATOMIC);
    return action;
}
@end
@interface TGExtra : UIViewController
@property UITableView *tableView;
@property BOOL isCheckingTemporaryFiles;
@property BOOL isClearingTemporaryFiles;
@property UIAlertController *alert;
- (void)confirmClearTemporaryFiles;
@end
@implementation TGExtra
- (void)presentViewController:(UIViewController *)controller animated:(BOOL)animated completion:(void (^)(void))completion {
    self.alert = (UIAlertController *)controller;
}
'''
tests = r'''
@end
static void confirm(TGExtra *controller) {
    UIAlertAction *action = controller.alert.actions.lastObject;
    NSCAssert(action.style == UIAlertActionStyleDestructive, @"Force cleanup requires a destructive confirmation");
    void (^handler)(UIAlertAction *) = objc_getAssociatedObject(action, &handlerKey);
    handler(action);
}
int main(void) { @autoreleasepool {
    TGExtra *controller = [TGExtra new];
    [controller confirmClearTemporaryFiles];
    NSCAssert(controller.isCheckingTemporaryFiles && !controller.alert && deletions == 0, @"Measure first without deleting or blocking the UI");
    [controller confirmClearTemporaryFiles];
    NSCAssert(measurements == 1, @"Ignore duplicate taps during measurement");
    usageCallback(7, 25000000, nil);
    NSString *size = [NSByteCountFormatter stringFromByteCount:25000000 countStyle:NSByteCountFormatterCountStyleFile];
    NSCAssert([controller.alert.message containsString:@"Files: 7"] && [controller.alert.message containsString:size], @"Show the measured file count and formatted size in the confirmation");
    NSCAssert(!controller.isCheckingTemporaryFiles && deletions == 0, @"Showing a confirmation never deletes files");
    UIAlertAction *cancel = controller.alert.actions.firstObject;
    NSCAssert(cancel.style == UIAlertActionStyleCancel && !objc_getAssociatedObject(cancel, &handlerKey), @"Cancellation preserves files");
    confirm(controller);
    NSCAssert(controller.isClearingTemporaryFiles && deletions == 1, @"Delete only after explicit confirmation and expose the busy state");
    [controller confirmClearTemporaryFiles];
    NSCAssert(measurements == 1 && deletions == 1, @"Ignore duplicate taps while clearing");
    clearCallback(nil);
    NSCAssert(!controller.isClearingTemporaryFiles && [toast isEqual:@"TEMPORARY_FILES_CLEARED"], @"Report successful cleanup and restore the button");

    controller.alert = nil;
    [controller confirmClearTemporaryFiles];
    NSError *error = [NSError errorWithDomain:@"cleanup-test" code:1 userInfo:@{NSLocalizedDescriptionKey: @"Cannot read files"}];
    usageCallback(0, 0, error);
    NSCAssert(!controller.alert && !controller.isCheckingTemporaryFiles && [toast isEqual:@"Cannot read files"] && deletions == 1, @"A failed scan shows its error, never a misleading empty confirmation");
    [controller confirmClearTemporaryFiles];
    usageCallback(0, 0, nil);
    NSCAssert([controller.alert.message containsString:@"Files: 0"], @"Show zero files honestly");
    confirm(controller);
    clearCallback(error);
    NSCAssert(!controller.isClearingTemporaryFiles && [toast isEqual:@"Cannot read files"], @"Report deletion failures and allow retry");
    puts("PASS real UIKit cleanup confirmation: count, size, cancellation, duplicate taps, busy states and errors");
} return 0; }
'''
with tempfile.TemporaryDirectory(prefix='tgextra-cleanup-confirmation-') as directory:
    directory = Path(directory)
    main = directory / 'main.m'
    main.write_text(support + source + tests)
    binary = directory / 'tests'
    subprocess.run(['xcrun', 'clang', '-target', f'{platform.machine()}-apple-ios17.0-macabi',
                    '-isysroot', str(sdk), '-iframework', str(frameworks), '-F', str(frameworks),
                    '-fobjc-arc', '-Werror', '-I', str(root / 'Sources/tgapi'),
                    '-framework', 'UIKit', '-framework', 'Foundation',
                    '-Wl,-rpath,/System/iOSSupport/System/Library/Frameworks', str(main), '-o', str(binary)], check=True)
    subprocess.run([str(binary)], check=True, timeout=20)
