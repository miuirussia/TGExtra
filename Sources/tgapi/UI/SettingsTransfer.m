#import "SettingsController.h"
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

@implementation TGExtra (Transfer)

- (void)exportSettings {
    NSError *error = nil;
    NSData *data = TGExtraExportSettings(&error);
    if (!data) { TGExtraShowToast(TGLoc(@"SETTINGS_TRANSFER_FAILED")); return; }
    NSURL *directory = [[NSURL fileURLWithPath:NSTemporaryDirectory()]
        URLByAppendingPathComponent:[@"TGExtraSettings-" stringByAppendingString:NSUUID.UUID.UUIDString] isDirectory:YES];
    if (![NSFileManager.defaultManager createDirectoryAtURL:directory withIntermediateDirectories:YES attributes:nil error:&error]) {
        TGExtraShowToast(TGLoc(@"SETTINGS_TRANSFER_FAILED")); return;
    }
    NSURL *url = [directory URLByAppendingPathComponent:@"TGExtra-settings.json"];
    if (![data writeToURL:url options:NSDataWritingAtomic error:&error]) {
        [NSFileManager.defaultManager removeItemAtURL:directory error:NULL];
        TGExtraShowToast(TGLoc(@"SETTINGS_TRANSFER_FAILED")); return;
    }
    UIActivityViewController *share = [[UIActivityViewController alloc] initWithActivityItems:@[url] applicationActivities:nil];
    share.popoverPresentationController.sourceView = self.view;
    share.popoverPresentationController.sourceRect = CGRectMake(CGRectGetMidX(self.view.bounds), CGRectGetMidY(self.view.bounds), 1, 1);
    share.completionWithItemsHandler = ^(UIActivityType type, BOOL completed, NSArray *items, NSError *error) {
        [NSFileManager.defaultManager removeItemAtURL:directory error:NULL];
    };
    [self presentViewController:share animated:YES completion:nil];
}

- (void)importSettings {
    UIDocumentPickerViewController *picker = [[UIDocumentPickerViewController alloc]
        initForOpeningContentTypes:@[UTTypeJSON] asCopy:YES];
    picker.delegate = self;
    [self presentViewController:picker animated:YES completion:nil];
}

- (void)documentPicker:(UIDocumentPickerViewController *)controller didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
    NSURL *url = urls.firstObject;
    if (!url) return;
    BOOL scoped = [url startAccessingSecurityScopedResource];
    NSNumber *size = nil;
    [url getResourceValue:&size forKey:NSURLFileSizeKey error:NULL];
    NSData *data = size && size.unsignedLongLongValue <= 1024 * 1024 ? [NSData dataWithContentsOfURL:url] : nil;
    if (scoped) [url stopAccessingSecurityScopedResource];
    NSError *error = nil;
    NSDictionary *values = data ? TGExtraValidateSettings(data, &error) : nil;
    if (!values) { TGExtraShowToast(TGLoc(@"SETTINGS_IMPORT_INVALID")); return; }
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:TGLoc(@"SETTINGS_IMPORT_TITLE")
        message:[NSString stringWithFormat:TGLoc(@"SETTINGS_IMPORT_CONFIRM"), (unsigned long)values.count]
        preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:TGLoc(@"CANCEL") style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:TGLoc(@"APPLY") style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        NSError *error = nil;
        if (!TGExtraImportSettings(data, &error)) { TGExtraShowToast(TGLoc(@"SETTINGS_TRANSFER_FAILED")); return; }
        [TLParser clearPendingGhostReads];
        [[TGExtraLocalization shared] loadDefault];
        [NSNotificationCenter.defaultCenter postNotificationName:@"LanguageChangedNotification" object:nil];
        [self.tableView reloadData];
        TGExtraShowToast(TGLoc(@"SETTINGS_IMPORT_DONE"));
    }]];
    // The picker may still be dismissing when its delegate runs.
    if (controller.presentingViewController) [controller dismissViewControllerAnimated:YES completion:^{
        [self presentViewController:alert animated:YES completion:nil];
    }];
    else [self presentViewController:alert animated:YES completion:nil];
}
@end
