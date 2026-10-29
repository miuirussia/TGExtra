#import "SettingsController.h"

@implementation TGExtra (Changes)

- (void)applyChanges {
  UIAlertController *alert =
      [UIAlertController alertControllerWithTitle:TGLoc(@"APPLY")
                                          message:TGLoc(@"APPLY_CHANGES")
                                   preferredStyle:UIAlertControllerStyleAlert];

  UIAlertAction *okAction = [UIAlertAction
      actionWithTitle:TGLoc(@"OK")
                style:UIAlertActionStyleDefault
              handler:^(UIAlertAction *_Nonnull action) {
                if (!TGExtraSavePreferences()) {
                  TGExtraShowToast(TGLoc(@"SETTINGS_SAVE_FAILED"));
                  return;
                }
                [[NSUserDefaults standardUserDefaults] synchronize];
                [[UIApplication sharedApplication]
                    performSelector:@selector(suspend)];
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                             (int64_t)(0.5 * NSEC_PER_SEC)),
                               dispatch_get_main_queue(), ^{
                                 exit(0);
                               });
              }];

  [alert addAction:okAction];

  UIAlertAction *cancelAction =
      [UIAlertAction actionWithTitle:TGLoc(@"CANCEL")
                               style:UIAlertActionStyleCancel
                             handler:nil];
  [alert addAction:cancelAction];
  [self presentViewController:alert animated:YES completion:nil];
}

- (void)switchChanged:(UISwitch *)sender {
  NSInteger adjustedTag = sender.tag - 1000;
  NSInteger section = adjustedTag / 1000;
  NSInteger row = adjustedTag % 1000;

  NSIndexPath *indexPath = [NSIndexPath indexPathForRow:row inSection:section];
  NSString *switchKey = [self switchKeyForIndexPath:indexPath];

  if (switchKey) {
    if ([switchKey isEqualToString:kGhostModeEnabled] && sender.isOn) {
      if (![self anyGhostSubFeatureEnabled]) {
        [sender setOn:NO animated:YES];
        [[NSUserDefaults standardUserDefaults] setBool:NO forKey:kGhostModeEnabled];

        UIAlertController *alert = [UIAlertController alertControllerWithTitle:TGLoc(@"GHOST_MODE_SECTION_HEADER")
                                                                       message:TGLoc(@"GHOST_MODE_NEEDS_SUBFEATURE")
                                                                preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:TGLoc(@"OK") style:UIAlertActionStyleDefault handler:nil]];
        [self presentViewController:alert animated:YES completion:nil];
        return;
      }
    }

    [[NSUserDefaults standardUserDefaults] setBool:sender.isOn
                                            forKey:switchKey];
    if (!TGExtraSavePreferences()) {
      TGExtraShowToast(TGLoc(@"SETTINGS_SAVE_FAILED"));
    }
    tgextraDiag("switch section=%ld row=%ld key=%{public}@ value=%d",
             (long)section, (long)row, switchKey, sender.isOn);
  } else {
    tgextraDiag("switch section=%ld row=%ld has NO KEY", (long)section, (long)row);
  }
}

- (NSString *)switchKeyForIndexPath:(NSIndexPath *)indexPath {
  return [TGExtraSettingRow rowForSection:indexPath.section row:indexPath.row].key;
}

- (BOOL)anyGhostSubFeatureEnabled {
  for (TGExtraSettingRow *row in [TGExtraSettingRow ghostRows]) {
    if ([[NSUserDefaults standardUserDefaults] boolForKey:row.key])
      return YES;
  }
  return NO;
}

@end
