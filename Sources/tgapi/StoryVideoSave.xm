#ifdef TGEXTRA_TESTING
#import "PhotoLibraryMocks.h"
#else
#import <Photos/Photos.h>
#endif
#import "Constants.h"
#import "StoryVideoExport.h"
#import "Logger/Logger.h"

static NSString *const kStoryExportFiles = @"TGExtraStoryExportFiles";

// Do not depend on Swift controller names or the queue used to start a save.
// Scope the hooks to Photos transactions with the bypass enabled, then check
// the actual input frame rate. The changes block runs on a Photos worker.
static BOOL tgextraShouldNormalizeVideoImport(void) {
    return [[NSUserDefaults standardUserDefaults] boolForKey:kDisableForwardRestriction];
}

static dispatch_block_t tgextraVideoChanges(dispatch_block_t changes,
                                          NSMutableArray<NSURL *> *outputs) {
    return ^{
        NSMutableDictionary *threadInfo = NSThread.currentThread.threadDictionary;
        id previous = threadInfo[kStoryExportFiles];
        threadInfo[kStoryExportFiles] = outputs;
        @try {
            changes();
        } @finally {
            if (previous) threadInfo[kStoryExportFiles] = previous;
            else [threadInfo removeObjectForKey:kStoryExportFiles];
        }
    };
}

static void tgextraRemoveVideoExports(NSArray<NSURL *> *outputs) {
    // Photos can read resources after the changes block returns.
    for (NSURL *url in outputs) {
        [[NSFileManager defaultManager] removeItemAtURL:url error:NULL];
    }
}

static NSURL *tgextraNormalizedVideoURL(NSURL *url) {
    NSMutableArray<NSURL *> *outputs = NSThread.currentThread.threadDictionary[kStoryExportFiles];
    if (!outputs || !TGExtraStoryVideoNeedsNormalization(url)) return url;
    NSURL *exported = TGExtraExportStoryVideo(url);
    if (!exported) {
        os_log_error(OS_LOG_DEFAULT, "[TGExtraStory] Video normalization failed; using original");
        return url;
    }
    [outputs addObject:exported];
    os_log(OS_LOG_DEFAULT, "[TGExtraStory] Normalized high-frame-rate video before Photos import");
    return exported;
}

%hook PHPhotoLibrary
- (void)performChanges:(dispatch_block_t)changeBlock
    completionHandler:(void (^)(BOOL, NSError *))completionHandler {
    if (!changeBlock || !tgextraShouldNormalizeVideoImport() ||
        NSThread.currentThread.threadDictionary[kStoryExportFiles]) {
        %orig;
        return;
    }
    NSMutableArray<NSURL *> *outputs = [NSMutableArray array];
    void (^wrappedCompletion)(BOOL, NSError *) = ^(BOOL success, NSError *error) {
        tgextraRemoveVideoExports(outputs);
        if (completionHandler) completionHandler(success, error);
    };
    %orig(tgextraVideoChanges(changeBlock, outputs), wrappedCompletion);
}

- (BOOL)performChangesAndWait:(dispatch_block_t)changeBlock error:(NSError **)error {
    if (!changeBlock || !tgextraShouldNormalizeVideoImport() ||
        NSThread.currentThread.threadDictionary[kStoryExportFiles]) return %orig;
    NSMutableArray<NSURL *> *outputs = [NSMutableArray array];
    BOOL success = NO;
    @try {
        success = %orig(tgextraVideoChanges(changeBlock, outputs), error);
    } @finally {
        tgextraRemoveVideoExports(outputs);
    }
    return success;
}
%end

%hook PHAssetChangeRequest
+ (instancetype)creationRequestForAssetFromVideoAtFileURL:(NSURL *)fileURL {
    return %orig(tgextraNormalizedVideoURL(fileURL));
}
%end

%hook PHAssetCreationRequest
- (void)addResourceWithType:(PHAssetResourceType)type fileURL:(NSURL *)fileURL
    options:(PHAssetResourceCreationOptions *)options {
    if (type != PHAssetResourceTypeVideo) {
        %orig;
        return;
    }
    NSURL *normalized = tgextraNormalizedVideoURL(fileURL);
    if (![normalized isEqual:fileURL] && options.shouldMoveFile) {
        options = [options copy];
        options.shouldMoveFile = NO;
    }
    %orig(type, normalized, options);
}

- (void)addResourceWithType:(PHAssetResourceType)type data:(NSData *)data
    options:(PHAssetResourceCreationOptions *)options {
    if (type != PHAssetResourceTypeVideo || !data.length ||
        !NSThread.currentThread.threadDictionary[kStoryExportFiles]) {
        %orig;
        return;
    }
    NSURL *input = [NSURL fileURLWithPath:[NSTemporaryDirectory()
        stringByAppendingPathComponent:[NSString stringWithFormat:@"TGExtraStoryInput-%@.mp4",
                                       NSUUID.UUID.UUIDString]]];
    if (![data writeToURL:input options:NSDataWritingAtomic error:NULL]) {
        %orig;
        return;
    }
    NSURL *normalized = tgextraNormalizedVideoURL(input);
    NSData *normalizedData = [normalized isEqual:input] ? nil : [NSData dataWithContentsOfURL:normalized];
    [[NSFileManager defaultManager] removeItemAtURL:input error:NULL];
    %orig(type, normalizedData ?: data, options);
}
%end
