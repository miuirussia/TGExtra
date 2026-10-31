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
cells = (root / 'Sources/tgapi/UI/SettingsTableCells.m').read_text()
cells = cells[cells.index('  } else if (indexPath.section == TOOLS) {'):cells.index('  } else if (indexPath.section == CREDITS)')]
cells = cells.replace('  } else if', '  if', 1) + '\n  }\n  return nil;\n'
menu = (root / 'Sources/tgapi/UI/TGExtra.m').read_text()
actions = menu[menu.index('  if (indexPath.section == TOOLS) {'):menu.index('  if (indexPath.section == CREDITS) {')]
support = r'''
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import "TemporaryFiles.h"
#import "SettingsRows.h"
#import "SettingsCells.h"
#import "FilePickerCache.h"
static NSString *toast;
static void TGExtraShowToast(NSString *text) { toast = text; }
static NSString *TGLoc(NSString *key) {
    return [key isEqual:@"TEMPORARY_FILES_USAGE"] ? @"Files: %lu\nSize: %@" : key;
}
static void (^usageCallback)(NSUInteger, unsigned long long, NSError *);
static void (^clearCallback)(NSError *);
static NSUInteger measurements, deletions, messagePrompts, cachePrompts, debugOpens;
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
@implementation TGExtraFilePickerCache
+ (void)sizeWithCompletion:(void (^)(NSString *))completion {}
+ (void)clearWithCompletion:(void (^)(NSError *))completion {}
@end
@interface TGExtra : UIViewController
@property UITableView *tableView;
@property BOOL isCleanupExpanded;
@property BOOL isClearingMessageData;
@property BOOL isCheckingTemporaryFiles;
@property BOOL isClearingTemporaryFiles;
@property UIAlertController *alert;
- (void)confirmClearTemporaryFiles;
- (UITableViewCell *)settingsCellForTableView:(UITableView *)tableView indexPath:(NSIndexPath *)indexPath;
- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath;
@end
@implementation TGExtra
- (void)presentViewController:(UIViewController *)controller animated:(BOOL)animated completion:(void (^)(void))completion {
    self.alert = (UIAlertController *)controller;
}
'''
table_methods = r'''
- (UIColor *)dynamicColorBW { return UIColor.labelColor; }
- (void)confirmClearMessageData { messagePrompts++; }
- (void)clearFilePickerFixCache { cachePrompts++; }
- (void)showDebugLog { debugOpens++; }
- (UITableViewCell *)settingsCellForTableView:(UITableView *)tableView indexPath:(NSIndexPath *)indexPath {
  UITableViewCell *cell;
''' + cells + '}\n- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {\n' + actions + '}\n'
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
    controller.tableView = [[UITableView alloc] initWithFrame:CGRectMake(0, 0, 375, 812) style:UITableViewStyleInsetGrouped];
    NSIndexPath *expander = [NSIndexPath indexPathForRow:0 inSection:TOOLS];
    UITableViewCell *collapsed = [controller settingsCellForTableView:controller.tableView indexPath:[NSIndexPath indexPathForRow:1 inSection:TOOLS]];
    NSCAssert([collapsed.textLabel.text isEqual:@"DEBUG_LOG_TITLE"], @"Collapsed cleanup leaves the debug log visible");
    [controller tableView:controller.tableView didSelectRowAtIndexPath:expander];
    NSCAssert(controller.isCleanupExpanded && !controller.alert && measurements == 0, @"Expanding cleanup only reveals actions");
    NSArray *titles = @[@"CLEANUP_TITLE", @"MESSAGE_DATA_CLEAR_TITLE", @"TEMPORARY_FILES_CLEAR_TITLE", @"CLEAR_FILE_PICKER_CACHE_TITLE", @"DEBUG_LOG_TITLE"];
    for (NSInteger row = 0; row < 5; row++) {
        NSIndexPath *path = [NSIndexPath indexPathForRow:row inSection:TOOLS];
        UITableViewCell *cell = [controller settingsCellForTableView:controller.tableView indexPath:path];
        NSCAssert([cell.textLabel.text isEqual:titles[row]] && (cell.accessibilityTraits & UIAccessibilityTraitButton), @"Expanded actions have the correct labels and VoiceOver roles");
        NSCAssert(cell.textLabel.adjustsFontForContentSizeCategory && cell.detailTextLabel.numberOfLines == 0, @"Cleanup supports large text and wrapped descriptions");
    }
    for (NSNumber *row in @[@1, @3, @4]) {
        [controller tableView:controller.tableView didSelectRowAtIndexPath:[NSIndexPath indexPathForRow:row.integerValue inSection:TOOLS]];
    }
    NSCAssert(messagePrompts == 1 && cachePrompts == 1 && debugOpens == 1, @"Expanded action positions remain correctly wired");
    [controller tableView:controller.tableView didSelectRowAtIndexPath:[NSIndexPath indexPathForRow:2 inSection:TOOLS]];
    NSCAssert(controller.isCheckingTemporaryFiles && !controller.alert && deletions == 0, @"Measure first without deleting or blocking the UI");
    UITableViewCell *busy = [controller settingsCellForTableView:controller.tableView indexPath:[NSIndexPath indexPathForRow:2 inSection:TOOLS]];
    NSCAssert(!busy.userInteractionEnabled && [busy.textLabel.text isEqual:@"TEMPORARY_FILES_CHECKING"] && (busy.accessibilityTraits & UIAccessibilityTraitNotEnabled), @"Busy cleanup rows show progress and disable interaction");
    [controller tableView:controller.tableView didSelectRowAtIndexPath:expander];
    NSCAssert(!controller.isCleanupExpanded && controller.isCheckingTemporaryFiles, @"Collapsing the menu preserves active cleanup state");
    [controller tableView:controller.tableView didSelectRowAtIndexPath:[NSIndexPath indexPathForRow:1 inSection:TOOLS]];
    NSCAssert(debugOpens == 2 && measurements == 1, @"The log remains accessible while cleanup is collapsed and busy");
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
    puts("PASS real UIKit cleanup expansion, row actions, collapse while busy, confirmation, cancellation and errors");
} return 0; }
'''
with tempfile.TemporaryDirectory(prefix='tgextra-cleanup-confirmation-') as directory:
    directory = Path(directory)
    main = directory / 'main.m'
    main.write_text(support + table_methods + source + tests)
    binary = directory / 'tests'
    subprocess.run(['xcrun', 'clang', '-target', f'{platform.machine()}-apple-ios17.0-macabi',
                    '-isysroot', str(sdk), '-iframework', str(frameworks), '-F', str(frameworks),
                    '-fobjc-arc', '-Werror', '-I', str(root / 'Sources/tgapi'),
                    '-I', str(root / 'Sources/tgapi/UI'), str(root / 'Sources/tgapi/UI/SettingsCells.m'),
                    '-framework', 'UIKit', '-framework', 'Foundation',
                    '-Wl,-rpath,/System/iOSSupport/System/Library/Frameworks', str(main), '-o', str(binary)], check=True)
    subprocess.run([str(binary)], check=True, timeout=20)
