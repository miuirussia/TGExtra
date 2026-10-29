#import <UIKit/UIKit.h>
#import <Photos/Photos.h>
#import <objc/runtime.h>
#import "PaidMedia.h"
#import "Constants.h"
#import "UI/Headers.h"

@interface NSObject (TGExtraPaidMediaDisplayNode)
- (UIView *)view;
@end

@interface TGExtraPaidMediaButton : UIButton
@property(nonatomic, weak) id footer;
@property(nonatomic) BOOL saving;
@property(nonatomic, strong) UIActivityIndicatorView *spinner;
@end

@implementation TGExtraPaidMediaButton
- (void)save {
    if (self.saving || ![NSUserDefaults.standardUserDefaults boolForKey:kDisableForwardRestriction]) return;
    id footer = self.footer;
    if (!footer) return;
    TGExtraPaidMediaFile *file = [TGExtraPaidMediaFile fileFromFooterNode:footer];
    if (!file) return;
    self.saving = YES;
    self.enabled = NO;
    self.imageView.hidden = YES;
    self.spinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
    self.spinner.color = self.tintColor;
    self.spinner.center = CGPointMake(CGRectGetMidX(self.bounds), CGRectGetMidY(self.bounds));
    [self addSubview:self.spinner];
    [self.spinner startAnimating];
    [PHPhotoLibrary requestAuthorizationForAccessLevel:PHAccessLevelAddOnly handler:^(PHAuthorizationStatus status) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (status != PHAuthorizationStatusAuthorized && status != PHAuthorizationStatusLimited) {
                [self finishedWithKey:@"PAID_MEDIA_PHOTOS_DENIED"];
                return;
            }
            TGExtraShowToast([TGExtraLocalization localizedStringForKey:@"PAID_MEDIA_SAVING"]);
            TGExtraDownloadPaidMedia(file, ^(NSURL *url, NSError *error) {
                if (!url || error) { [self failed:error stage:@"download"]; return; }
                TGExtraImportPaidMedia(url, file.video, ^(NSString *identifier, NSError *photoError) {
                    [NSFileManager.defaultManager removeItemAtURL:url error:NULL];
                    if (identifier.length && !photoError) {
                        [NSUserDefaults.standardUserDefaults setObject:
                            [NSString stringWithFormat:@"%@ Photos created asset %@", NSDate.date, identifier]
                            forKey:@"TGExtraPaidMediaLastImport"];
                        [self finishedWithKey:@"PAID_MEDIA_SAVED"];
                    } else [self failed:photoError stage:@"Photos"];
                });
            });
        });
    }];
}

- (void)finishedWithKey:(NSString *)key {
    [self finishedWithMessage:[TGExtraLocalization localizedStringForKey:key]];
}

- (void)failed:(NSError *)error stage:(NSString *)stage {
    NSString *detail = [NSString stringWithFormat:@"%@: %@ (%@:%ld)", stage,
        error.localizedDescription ?: @"Unknown error", error.domain ?: @"TGExtra.PaidMedia", (long)error.code];
    [NSUserDefaults.standardUserDefaults setObject:[NSString stringWithFormat:@"%@ %@", NSDate.date, detail]
        forKey:@"TGExtraPaidMediaLastError"];
    [self finishedWithMessage:[NSString stringWithFormat:@"%@\n%@",
        [TGExtraLocalization localizedStringForKey:@"PAID_MEDIA_SAVE_FAILED"], detail]];
}

- (void)finishedWithMessage:(NSString *)message {
    self.saving = NO;
    self.enabled = YES;
    self.imageView.hidden = NO;
    [self.spinner removeFromSuperview];
    self.spinner = nil;
    TGExtraShowToast(message);
}
@end

void TGExtraUpdatePaidMediaSaveButton(id node) {
    if (![NSStringFromClass([node class]) hasSuffix:@".ChatItemGalleryFooterContentNode"]) return;
    static char buttonKey;
    TGExtraPaidMediaButton *button = objc_getAssociatedObject(node, &buttonKey);
    if (![NSUserDefaults.standardUserDefaults boolForKey:kDisableForwardRestriction] ||
        ![TGExtraPaidMediaFile fileFromFooterNode:node]) {
        button.hidden = YES;
        return;
    }
    button.hidden = YES;
    id content = [TGExtraPaidMediaFile contentNodeFromFooter:node];
    if (![content respondsToSelector:@selector(view)]) return;
    UIView *view = [content view];
    CGFloat bottomInset = [TGExtraPaidMediaFile bottomInsetFromFooter:node];
    if (!view || view.bounds.size.width < 44 || view.bounds.size.height < bottomInset + 54) return;
    if (!button) {
        button = [TGExtraPaidMediaButton buttonWithType:UIButtonTypeSystem];
        button.footer = node;
        button.tintColor = UIColor.whiteColor;
        [button setImage:[UIImage systemImageNamed:@"arrow.down.to.line"] forState:UIControlStateNormal];
        button.accessibilityIdentifier = @"TGExtra.SavePaidMedia";
        [button addTarget:button action:@selector(save) forControlEvents:UIControlEventTouchUpInside];
        objc_setAssociatedObject(node, &buttonKey, button, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    if (button.superview != view) [view addSubview:button];
    button.frame = CGRectMake(8 + view.safeAreaInsets.left, view.bounds.size.height - bottomInset - 49, 44, 44);
    button.accessibilityLabel = [TGExtraLocalization localizedStringForKey:@"PAID_MEDIA_SAVE"];
    button.hidden = NO;
    [view bringSubviewToFront:button];
}
