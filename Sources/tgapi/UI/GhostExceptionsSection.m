#import "SettingsController.h"
#import "GhostExceptionDisplayName.h"
@implementation TGExtra (GhostExceptions)

- (BOOL)tableView:(UITableView *)tableView
    canEditRowAtIndexPath:(NSIndexPath *)indexPath {
  return indexPath.section == GHOST_EXCEPTIONS &&
         [TGExtraGhostExceptions all].count > 0;
}

- (UITableViewCellEditingStyle)tableView:(UITableView *)tableView
           editingStyleForRowAtIndexPath:(NSIndexPath *)indexPath {
  return indexPath.section == GHOST_EXCEPTIONS
             ? UITableViewCellEditingStyleDelete
             : UITableViewCellEditingStyleNone;
}

- (void)tableView:(UITableView *)tableView
    commitEditingStyle:(UITableViewCellEditingStyle)editingStyle
     forRowAtIndexPath:(NSIndexPath *)indexPath {
  if (editingStyle != UITableViewCellEditingStyleDelete) return;
  if (indexPath.section != GHOST_EXCEPTIONS) return;

  NSArray<NSDictionary *> *exceptions = [TGExtraGhostExceptions all];
  if (indexPath.row >= (NSInteger)exceptions.count) return;

  NSNumber *peerId = exceptions[indexPath.row][kTGExtraGhostExceptionId];
  [TGExtraGhostExceptions removePeerId:peerId.longLongValue];
  [self reloadGhostExceptions];
}

- (void)tableView:(UITableView *)tableView
    accessoryButtonTappedForRowWithIndexPath:(NSIndexPath *)indexPath {
  if (indexPath.section != GHOST_EXCEPTIONS) return;

  NSArray<NSDictionary *> *exceptions = [TGExtraGhostExceptions all];
  if (indexPath.row >= (NSInteger)exceptions.count) return;

  [self showRenamePromptForException:exceptions[indexPath.row]];
}

- (void)reloadGhostExceptions {
  [self.tableView
        reloadSections:[NSIndexSet indexSetWithIndex:GHOST_EXCEPTIONS]
      withRowAnimation:UITableViewRowAnimationAutomatic];
}

- (void)showRenamePromptForException:(NSDictionary *)entry {
  NSNumber *peerId = entry[kTGExtraGhostExceptionId];

  UIAlertController *alert = [UIAlertController
      alertControllerWithTitle:TGLoc(@"GHOST_EXCEPTIONS_RENAME_TITLE")
                       message:TGLoc(@"GHOST_EXCEPTIONS_RENAME_MESSAGE")
                preferredStyle:UIAlertControllerStyleAlert];

  [alert addTextFieldWithConfigurationHandler:^(UITextField *field) {
    field.text = entry[kTGExtraGhostExceptionCustom];
    field.placeholder = ghostExceptionDisplayName(entry);
    field.clearButtonMode = UITextFieldViewModeWhileEditing;
  }];

  [alert addAction:[UIAlertAction actionWithTitle:TGLoc(@"CANCEL")
                                            style:UIAlertActionStyleCancel
                                          handler:nil]];

  __weak typeof(self) weakSelf = self;
  __weak UIAlertController *weakAlert = alert;
  [alert addAction:[UIAlertAction
                       actionWithTitle:TGLoc(@"SAVE")
                                 style:UIAlertActionStyleDefault
                               handler:^(UIAlertAction *action) {
                                 NSString *newName = weakAlert.textFields.firstObject.text;
                                 [TGExtraGhostExceptions setCustomName:newName
                                                          forPeerId:peerId.longLongValue];
                                 [weakSelf reloadGhostExceptions];
                               }]];

  [self presentViewController:alert animated:YES completion:nil];
}

- (void)openProfileForException:(NSDictionary *)entry {
  NSString *username = entry[kTGExtraGhostExceptionUsername];
  NSNumber *peerId = entry[kTGExtraGhostExceptionId];

  NSString *urlString =
      username.length
          ? [NSString stringWithFormat:@"tg://resolve?domain=%@&profile", username]
          : [NSString stringWithFormat:@"tg://user?id=%@", peerId];

  NSURL *url = [NSURL URLWithString:urlString];
  if (!url) return;

  [self dismissViewControllerAnimated:YES
                           completion:^{
                             TGExtraOpenTelegramURL(url);
                           }];
}

@end
