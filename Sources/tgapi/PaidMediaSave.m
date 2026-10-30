#import <UIKit/UIKit.h>
#import <Photos/Photos.h>
#import <objc/runtime.h>
#import "PaidMedia.h"
#import "Constants.h"
#import "UI/Headers.h"

@interface NSObject (TGExtraPaidMediaDisplayNode)
- (UIView *)view;
- (id)supernode;
@end

@interface TGExtraPaidMediaSaveAction : NSObject
@property(nonatomic, weak) id footer;
@property(nonatomic, weak) UINavigationItem *navigationItem;
@property(nonatomic, strong) UIBarButtonItem *item;
@property(nonatomic, copy) NSArray<UIBarButtonItem *> *originalItems;
@property(nonatomic, strong) UIImage *downloadImage;
@property(nonatomic) BOOL saving;
@end

@implementation TGExtraPaidMediaSaveAction
- (void)restore {
    if ([self.navigationItem.rightBarButtonItems containsObject:self.item]) {
        self.navigationItem.rightBarButtonItems = self.originalItems;
    }
    self.originalItems = nil;
    self.footer = nil;
}

- (void)save {
    if (self.saving || ![NSUserDefaults.standardUserDefaults boolForKey:kDisableForwardRestriction]) return;
    id footer = self.footer;
    if (!footer) return;
    TGExtraPaidMediaFile *file = [TGExtraPaidMediaFile fileFromFooterNode:footer];
    if (!file) return;
    self.saving = YES;
    self.item.enabled = NO;
    self.item.image = [UIImage systemImageNamed:@"hourglass"];
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
    self.item.enabled = YES;
    self.item.image = self.downloadImage;
    TGExtraShowToast(message);
}
@end

void TGExtraUpdatePaidMediaSaveButton(id node) {
    NSString *name = NSStringFromClass([node class]);
    id container;
    if ([name hasSuffix:@".GalleryFooterNode"]) {
        container = node;
    } else if ([name hasSuffix:@".ChatItemGalleryFooterContentNode"] &&
               [node respondsToSelector:@selector(supernode)]) {
        container = [node supernode];
    } else return;
    if (![NSStringFromClass([container class]) hasSuffix:@".GalleryFooterNode"] ||
        ![container respondsToSelector:@selector(view)]) return;

    UIViewController *controller = nil;
    for (UIResponder *responder = [container view]; responder; responder = responder.nextResponder) {
        if ([responder isKindOfClass:UIViewController.class] &&
            [NSStringFromClass([responder class]) hasSuffix:@".GalleryController"]) {
            controller = (UIViewController *)responder;
            break;
        }
    }
    if (!controller) return;
    id footer = [TGExtraPaidMediaFile currentFooterNodeFromGalleryFooter:container];
    UINavigationItem *navigationItem = controller.navigationItem;
    static char actionKey;
    TGExtraPaidMediaSaveAction *action = objc_getAssociatedObject(navigationItem, &actionKey);
    if (![NSUserDefaults.standardUserDefaults boolForKey:kDisableForwardRestriction] ||
        !footer || ![TGExtraPaidMediaFile fileFromFooterNode:footer]) {
        [action restore];
        return;
    }
    if (!action) {
        action = [TGExtraPaidMediaSaveAction new];
        action.navigationItem = navigationItem;
        action.downloadImage = [UIImage systemImageNamed:@"arrow.down.to.line"
            withConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:21 weight:UIImageSymbolWeightRegular]];
        // A standard image item lets Telegram render its own glass and dispatch the action.
        action.item = [[UIBarButtonItem alloc] initWithImage:action.downloadImage
            style:UIBarButtonItemStylePlain target:action action:@selector(save)];
        action.item.accessibilityIdentifier = @"TGExtra.SavePaidMedia";
        objc_setAssociatedObject(navigationItem, &actionKey, action, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    action.footer = footer;
    action.item.accessibilityLabel = [TGExtraLocalization localizedStringForKey:@"PAID_MEDIA_SAVE"];
    if (![navigationItem.rightBarButtonItems containsObject:action.item]) {
        action.originalItems = navigationItem.rightBarButtonItems;
        navigationItem.rightBarButtonItems = @[action.item];
    }
}
