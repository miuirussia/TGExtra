#import "SettingsController.h"
#import "DebugLogViewController.h"

@implementation TGExtra (DebugLog)

- (void)showDebugLog {
  [self.navigationController pushViewController:[TGExtraDebugLogViewController new] animated:YES];
}

@end
