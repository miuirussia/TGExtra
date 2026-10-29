#import "SettingsController.h"

@implementation TGExtra (DebugLog)

- (void)showDebugLog {
  NSString *logContent = TGExtraReadLog();

  if (!logContent || logContent.length == 0) {
    logContent = @"";
  } else if (logContent.length > 3000) {
    logContent = [NSString stringWithFormat:@"...(last 3000 chars)\n%@",
                  [logContent substringFromIndex:logContent.length - 3000]];
  }
  for (NSString *key in @[@"TGExtraCaptureHookStatus", @"TGExtraCaptureCanvasStatus", @"TGExtraPaidCaptureStatus",
                         @"TGExtraPaidMediaLastImport", @"TGExtraPaidMediaLastError"]) {
    NSString *entry = [NSUserDefaults.standardUserDefaults stringForKey:key];
    if (entry.length) logContent = [logContent stringByAppendingFormat:@"%@%@: %@", logContent.length ? @"\n\n" : @"", key, entry];
  }
  if (!logContent.length) logContent = TGLoc(@"DEBUG_LOG_EMPTY");

  UIAlertController *alert = [UIAlertController
      alertControllerWithTitle:TGLoc(@"DEBUG_LOG_TITLE")
                       message:logContent
                preferredStyle:UIAlertControllerStyleAlert];

  [alert addAction:[UIAlertAction actionWithTitle:TGLoc(@"DEBUG_LOG_COPY") style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
    [UIPasteboard generalPasteboard].string = logContent;
  }]];
  [alert addAction:[UIAlertAction actionWithTitle:TGLoc(@"DEBUG_LOG_CLEAR") style:UIAlertActionStyleDestructive handler:^(UIAlertAction *a) {
    TGExtraClearLog();
    for (NSString *key in @[@"TGExtraPaidMediaLastError", @"TGExtraPaidMediaLastImport", @"TGExtraPaidCaptureStatus"]) {
      [NSUserDefaults.standardUserDefaults removeObjectForKey:key];
    }
  }]];
  [alert addAction:[UIAlertAction actionWithTitle:TGLoc(@"OK") style:UIAlertActionStyleCancel handler:nil]];

  [self presentViewController:alert animated:YES completion:nil];
}

@end
