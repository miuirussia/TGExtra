#import <UIKit/UIKit.h>
#import <Photos/Photos.h>
#import "Constants.h"
#import "StoryVideoExport.h"

// Story saving uses a Swift-only function, but its final Photos transaction
// is public Objective-C. Detect the viewer before Photos moves the changes
// block to its background queue. Include underlying presented controllers:
// Telegram shows a SaveProgressScreen over the story during the import.
static BOOL tgextraHasStoryViewer(UIViewController *controller, NSUInteger depth) {
    if (!controller || depth > 16) return NO;
    if ([NSStringFromClass(controller.class) containsString:@"StoryContainerScreen"] &&
        controller.isViewLoaded && controller.view.window) return YES;
    if (tgextraHasStoryViewer(controller.presentedViewController, depth + 1)) return YES;
    for (UIViewController *child in controller.childViewControllers) {
        if (tgextraHasStoryViewer(child, depth + 1)) return YES;
    }
    return NO;
}

static BOOL tgextraShouldExportStory(void) {
    if (![[NSUserDefaults standardUserDefaults] boolForKey:kDisableForwardRestriction]) return NO;
    // The host's saveToCameraRoll invokes performChanges on the main queue.
    // Do not synchronously query UIKit from Photos' own worker queue.
    if (![NSThread isMainThread]) return NO;
    for (UIWindow *window in UIApplication.sharedApplication.windows) {
        if (!window.hidden && tgextraHasStoryViewer(window.rootViewController, 0)) return YES;
    }
    return NO;
}

static NSString *const kStoryExportFiles = @"TGExtraStoryExportFiles";

%hook PHPhotoLibrary
- (void)performChanges:(dispatch_block_t)changeBlock
    completionHandler:(void (^)(BOOL, NSError *))completionHandler {
    if (!changeBlock || !tgextraShouldExportStory()) {
        %orig;
        return;
    }
    NSMutableArray<NSURL *> *outputs = [NSMutableArray array];
    dispatch_block_t wrappedChanges = ^{
        NSMutableDictionary *threadInfo = NSThread.currentThread.threadDictionary;
        id previous = threadInfo[kStoryExportFiles];
        threadInfo[kStoryExportFiles] = outputs;
        @try {
            changeBlock();
        } @finally {
            if (previous) threadInfo[kStoryExportFiles] = previous;
            else [threadInfo removeObjectForKey:kStoryExportFiles];
        }
    };
    void (^wrappedCompletion)(BOOL, NSError *) = ^(BOOL success, NSError *error) {
        // Photos may read file resources after the changes block returns.
        // Keep our files until the transaction's completion, including errors.
        for (NSURL *url in outputs) {
            [[NSFileManager defaultManager] removeItemAtURL:url error:NULL];
        }
        if (completionHandler) completionHandler(success, error);
    };
    %orig(wrappedChanges, wrappedCompletion);
}
%end

%hook PHAssetChangeRequest
+ (instancetype)creationRequestForAssetFromVideoAtFileURL:(NSURL *)fileURL {
    NSMutableArray<NSURL *> *outputs = NSThread.currentThread.threadDictionary[kStoryExportFiles];
    if (!outputs) return %orig;
    // performChanges executes this on a Photos background queue, so rendering
    // does not block the viewer or its progress screen. Failed exports retain
    // Telegram's original save path.
    NSURL *exported = TGExtraExportStoryVideo(fileURL);
    if (!exported) return %orig;
    [outputs addObject:exported];
    return %orig(exported);
}
%end
