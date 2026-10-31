#import <UIKit/UIKit.h>
#import <Photos/Photos.h>
#import <objc/runtime.h>
#import "PaidMedia.h"

@interface SaveDefaults : NSUserDefaults
@property BOOL savingEnabled;
@end
@implementation SaveDefaults
- (BOOL)boolForKey:(NSString *)key { return self.savingEnabled; }
- (void)setObject:(id)value forKey:(NSString *)key {}
@end

@interface SaveTestNode : NSObject
@property UIView *view;
@property SaveTestNode *supernode;
@property SaveTestNode *currentFooterContentNode;
@property BOOL unlocked;
@end
@implementation SaveTestNode @end

static id downloadedFooter;
static void (^downloadCompletion)(NSURL *, NSError *);
static TGExtraPaidMediaFile *testFile;
@interface TGExtraPaidMediaFile ()
@property(nonatomic, readwrite) BOOL video;
@property(nonatomic, readwrite) BOOL nativeOnly;
@end
@implementation TGExtraPaidMediaFile
+ (instancetype)fileFromFooterNode:(SaveTestNode *)footer {
    if ([NSStringFromClass(footer.class) hasSuffix:@".SecretMediaPreviewController"]) {
        downloadedFooter = footer;
        return testFile;
    }
    if (!footer.unlocked) return nil;
    downloadedFooter = footer;
    return testFile;
}
+ (id)currentFooterNodeFromGalleryFooter:(SaveTestNode *)container { return container.currentFooterContentNode; }
+ (id)footerNodeFromItem:(id)item { return nil; }
+ (BOOL)isUnlockedPaidItem:(id)item { return NO; }
+ (void)bindGalleryItem:(id)item {}
- (NSObject *)context { return nil; }
- (NSInteger)masterDatacenterId { return 0; }
- (NSInteger)datacenterId { return 0; }
- (int64_t)size { return 0; }
- (NSString *)cachePath { return nil; }
- (NSData *)downloadRequestAtOffset:(int64_t)offset { return nil; }
- (BOOL)beginNativeDownload { return NO; }
- (NSNumber *)nativeDownloadProgress { return nil; }
@end

@interface TGExtraLocalization : NSObject
+ (NSString *)localizedStringForKey:(NSString *)key;
@end
@implementation TGExtraLocalization
+ (NSString *)localizedStringForKey:(NSString *)key { return key; }
@end
void TGExtraShowToast(NSString *text) {}
void TGExtraDownloadPaidMedia(TGExtraPaidMediaFile *file, void (^completion)(NSURL *, NSError *)) {
    downloadCompletion = completion;
}
void TGExtraImportPaidMedia(NSURL *url, BOOL video, void (^completion)(NSString *, NSError *)) {
    NSCAssert(NO, @"Failed download cannot be imported");
}

static void registerClass(Class parent, const char *name) {
    objc_registerClassPair(objc_allocateClassPair(parent, name, 0));
}

int main(void) {
    @autoreleasepool {
        SaveDefaults *defaults = [SaveDefaults new];
        defaults.savingEnabled = YES;
        method_setImplementation(class_getClassMethod(NSUserDefaults.class, @selector(standardUserDefaults)),
            imp_implementationWithBlock(^id(id cls) { return defaults; }));
        method_setImplementation(class_getClassMethod(PHPhotoLibrary.class,
            @selector(requestAuthorizationForAccessLevel:handler:)),
            imp_implementationWithBlock(^(id cls, PHAccessLevel level, void (^handler)(PHAuthorizationStatus)) {
                handler(PHAuthorizationStatusAuthorized);
            }));
        testFile = [TGExtraPaidMediaFile new];
        registerClass(UIViewController.class, "GalleryUI.GalleryController");
        registerClass(SaveTestNode.class, "GalleryUI.GalleryFooterNode");
        registerClass(SaveTestNode.class, "GalleryUI.ChatItemGalleryFooterContentNode");
        UIViewController *controller = [NSClassFromString(@"GalleryUI.GalleryController") new];
        [controller loadViewIfNeeded];
        SaveTestNode *container = [NSClassFromString(@"GalleryUI.GalleryFooterNode") new];
        container.view = [[UIView alloc] initWithFrame:controller.view.bounds];
        [controller.view addSubview:container.view];
        SaveTestNode *photo = [NSClassFromString(@"GalleryUI.ChatItemGalleryFooterContentNode") new];
        photo.supernode = container;
        photo.unlocked = YES;
        container.currentFooterContentNode = photo;
        // Reproduce the existing empty custom button, whose view does not render or respond.
        UIBarButtonItem *empty = [[UIBarButtonItem alloc] initWithCustomView:[UIView new]];
        controller.navigationItem.rightBarButtonItems = @[empty];
        TGExtraUpdatePaidMediaSaveButton(container);
        UIBarButtonItem *save = controller.navigationItem.rightBarButtonItem;
        NSCAssert(save != empty && save.image && !save.customView && save.target && save.action,
                  @"Replace the empty item with a native image and its own action");
        NSCAssert([save.accessibilityIdentifier isEqual:@"TGExtra.SavePaidMedia"], @"Accessible save item");
        TGExtraUpdatePaidMediaSaveButton(photo);
        NSCAssert(controller.navigationItem.rightBarButtonItem == save, @"Layout reuses the item");
        SaveTestNode *video = [NSClassFromString(@"GalleryUI.ChatItemGalleryFooterContentNode") new];
        video.supernode = container;
        video.unlocked = YES;
        container.currentFooterContentNode = video;
        UIBarButtonItem *videoEmpty = [[UIBarButtonItem alloc] initWithCustomView:[UIView new]];
        controller.navigationItem.rightBarButtonItems = @[videoEmpty];
        TGExtraUpdatePaidMediaSaveButton(photo);
        downloadedFooter = nil;
        IMP handler = [save.target methodForSelector:save.action];
        NSCAssert(handler, @"The navigation item exposes a callable save action");
        ((void (*)(id, SEL))handler)(save.target, save.action);
        NSCAssert(downloadedFooter == video, @"A late photo layout must save the active video");
        NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:2];
        while (!downloadCompletion && deadline.timeIntervalSinceNow > 0) {
            [NSRunLoop.mainRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
        }
        NSCAssert(downloadCompletion && !save.enabled && save.image, @"Saving shows a busy icon and disables repeat taps");
        downloadCompletion(nil, [NSError errorWithDomain:@"test" code:1 userInfo:nil]);
        downloadCompletion = nil;
        NSCAssert(save.enabled && save.image, @"Failed saving restores the download icon and action");
        defaults.savingEnabled = NO;
        TGExtraUpdatePaidMediaSaveButton(container);
        NSCAssert(controller.navigationItem.rightBarButtonItem == videoEmpty, @"Disabling restores current native controls");
        defaults.savingEnabled = YES;
        TGExtraUpdatePaidMediaSaveButton(container);
        video.unlocked = NO;
        TGExtraUpdatePaidMediaSaveButton(container);
        NSCAssert(controller.navigationItem.rightBarButtonItem == videoEmpty, @"Locked media has no download action");
        container.currentFooterContentNode = nil;
        TGExtraUpdatePaidMediaSaveButton(container);
        registerClass(UIViewController.class, "GalleryUI.SecretMediaPreviewController");
        UIViewController *preview = [NSClassFromString(@"GalleryUI.SecretMediaPreviewController") new];
        [preview loadViewIfNeeded];
        [preview.view addSubview:container.view];
        testFile.nativeOnly = YES;
        TGExtraUpdatePaidMediaSaveButton(container);
        UIBarButtonItem *secretSave = preview.navigationItem.rightBarButtonItem;
        NSCAssert([secretSave.accessibilityIdentifier isEqual:@"TGExtra.SaveSecretMedia"] && secretSave.image,
                  @"Disappearing-media preview exposes its own save action without a footer message");
        downloadedFooter = nil;
        ((void (*)(id, SEL))[secretSave.target methodForSelector:secretSave.action])(secretSave.target, secretSave.action);
        NSCAssert(downloadedFooter == preview, @"Secret save resolves the preview's current message");
        defaults.savingEnabled = NO;
        TGExtraUpdatePaidMediaSaveButton(container);
        NSCAssert(!preview.navigationItem.rightBarButtonItem, @"Disabling restores the preview navigation item");
        puts("PASS real UIKit paid save: empty native item replacement, image, action dispatch, active page, busy state and restoration");
    }
    return 0;
}
