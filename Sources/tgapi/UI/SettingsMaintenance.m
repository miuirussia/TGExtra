#import "SettingsController.h"
#import "FilePickerCache.h"
#import "../TemporaryFiles.h"

@implementation TGExtra (Maintenance)

- (void)confirmClearTemporaryFiles {
  if (self.isClearingTemporaryFiles || self.isCheckingTemporaryFiles) return;
  self.isCheckingTemporaryFiles = YES;
  NSIndexSet *section = [NSIndexSet indexSetWithIndex:MESSAGE_DATA];
  [self.tableView reloadSections:section withRowAnimation:UITableViewRowAnimationNone];
  [TGExtraTemporaryFiles usageWithCompletion:^(NSUInteger count, unsigned long long bytes, NSError *error) {
    self.isCheckingTemporaryFiles = NO;
    [self.tableView reloadSections:section withRowAnimation:UITableViewRowAnimationNone];
    if (error) { TGExtraShowToast(error.localizedDescription); return; }
    NSString *size = [NSByteCountFormatter stringFromByteCount:(int64_t)MIN(bytes, (unsigned long long)INT64_MAX)
                                                   countStyle:NSByteCountFormatterCountStyleFile];
    NSString *usage = [NSString stringWithFormat:TGLoc(@"TEMPORARY_FILES_USAGE"), (unsigned long)count, size];
    UIAlertController *alert = [UIAlertController
        alertControllerWithTitle:TGLoc(@"TEMPORARY_FILES_CLEAR_TITLE")
                         message:[NSString stringWithFormat:@"%@\n\n%@", usage, TGLoc(@"TEMPORARY_FILES_CLEAR_CONFIRM")]
                  preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:TGLoc(@"CANCEL")
        style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:TGLoc(@"TEMPORARY_FILES_CLEAR_TITLE")
        style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action) {
          self.isClearingTemporaryFiles = YES;
          [self.tableView reloadSections:section withRowAnimation:UITableViewRowAnimationNone];
          [TGExtraTemporaryFiles clearWithCompletion:^(NSError *error) {
            self.isClearingTemporaryFiles = NO;
            [self.tableView reloadSections:section withRowAnimation:UITableViewRowAnimationNone];
            [self.tableView reloadSections:[NSIndexSet indexSetWithIndex:FILE_FIXER]
                         withRowAnimation:UITableViewRowAnimationNone];
            TGExtraShowToast(error ? error.localizedDescription : TGLoc(@"TEMPORARY_FILES_CLEARED"));
          }];
        }]];
    [self presentViewController:alert animated:YES completion:nil];
  }];
}

- (void)confirmClearMessageData {
  if (self.isClearingMessageData) return;
  UIAlertController *alert = [UIAlertController
      alertControllerWithTitle:TGLoc(@"MESSAGE_DATA_CLEAR_TITLE")
                       message:TGLoc(@"MESSAGE_DATA_CLEAR_CONFIRM")
                preferredStyle:UIAlertControllerStyleAlert];
  [alert addAction:[UIAlertAction actionWithTitle:TGLoc(@"CANCEL")
      style:UIAlertActionStyleCancel handler:nil]];
  [alert addAction:[UIAlertAction actionWithTitle:TGLoc(@"MESSAGE_DATA_CLEAR_TITLE")
      style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action) {
        self.isClearingMessageData = YES;
        NSIndexSet *section = [NSIndexSet indexSetWithIndex:MESSAGE_DATA];
        [self.tableView reloadSections:section withRowAnimation:UITableViewRowAnimationNone];
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
          BOOL cleared = [TLParser clearMessageData];
          dispatch_async(dispatch_get_main_queue(), ^{
            self.isClearingMessageData = NO;
            [self.tableView reloadSections:section withRowAnimation:UITableViewRowAnimationNone];
            TGExtraShowToast(TGLoc(cleared ? @"MESSAGE_DATA_CLEARED" : @"MESSAGE_DATA_CLEAR_FAILED"));
          });
        });
      }]];
  [self presentViewController:alert animated:YES completion:nil];
}

- (void)clearFilePickerFixCache {
  UIAlertController *alert = [UIAlertController
      alertControllerWithTitle:TGLoc(@"CACHE_CLEAR_WARNING_TITLE")
                       message:TGLoc(@"CACHE_CLEAR_WARNING_MESSAGE")
                preferredStyle:UIAlertControllerStyleAlert];

  UIAlertAction *okAction = [UIAlertAction
      actionWithTitle:TGLoc(@"OK")
                style:UIAlertActionStyleDestructive
              handler:^(UIAlertAction *action) {
                [TGExtraFilePickerCache clearWithCompletion:^(NSError *error) {
                  if (error) { TGExtraShowToast(error.localizedDescription); return; }
                  [self.tableView reloadSections:[NSIndexSet indexSetWithIndex:FILE_FIXER]
                                withRowAnimation:UITableViewRowAnimationAutomatic];
                }];
              }];

  UIAlertAction *cancelAction =
      [UIAlertAction actionWithTitle:TGLoc(@"CANCEL")
                               style:UIAlertActionStyleCancel
                             handler:nil];

  [alert addAction:cancelAction];
  [alert addAction:okAction];

  [self presentViewController:alert animated:YES completion:nil];
}

@end
