#import "SettingsController.h"
#import "FilePickerCache.h"

@implementation TGExtra (Maintenance)

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
