#import "Support/PhotoLibraryMocks.h"
#import <AVFoundation/AVFoundation.h>
#import <objc/runtime.h>
#import "../Sources/tgapi/Constants.h"
#import "../Sources/tgapi/StoryVideoExport.h"
#import <math.h>

static NSString *const kImports = @"TGExtraTestImports";
static BOOL bypassEnabled;

static void check(BOOL condition, NSString *message) {
    if (!condition) { NSLog(@"FAIL %@", message); exit(1); }
}

@implementation PHAssetResourceCreationOptions
- (id)copyWithZone:(NSZone *)zone {
    PHAssetResourceCreationOptions *copy = [PHAssetResourceCreationOptions new];
    copy.shouldMoveFile = self.shouldMoveFile;
    return copy;
}
@end

@implementation PHAssetChangeRequest
+ (instancetype)creationRequestForAssetFromVideoAtFileURL:(NSURL *)url {
    [NSThread.currentThread.threadDictionary[kImports] addObject:@{@"type": @2, @"url": url}];
    return [self new];
}
@end

@implementation PHAssetCreationRequest
- (void)addResourceWithType:(PHAssetResourceType)type fileURL:(NSURL *)url
                   options:(PHAssetResourceCreationOptions *)options {
    [NSThread.currentThread.threadDictionary[kImports] addObject:
        @{@"type": @(type), @"url": url, @"move": @(options.shouldMoveFile)}];
}
- (void)addResourceWithType:(PHAssetResourceType)type data:(NSData *)data
                   options:(PHAssetResourceCreationOptions *)options {
    [NSThread.currentThread.threadDictionary[kImports] addObject:@{@"type": @(type), @"data": data}];
}
@end

@implementation PHPhotoLibrary
- (void)performChanges:(dispatch_block_t)changes completionHandler:(void (^)(BOOL, NSError *))completion {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        @autoreleasepool {
            NSError *error = nil;
            BOOL success = [self performChangesAndWait:changes error:&error];
            if (completion) completion(success, error);
        }
    });
}
- (BOOL)performChangesAndWait:(dispatch_block_t)changes error:(NSError **)error {
    NSThread.currentThread.threadDictionary[kImports] = [NSMutableArray array];
    changes();
    NSMutableArray *imports = [NSMutableArray array];
    // Simulate Photos reading the resource AFTER the changes block returns.
    for (NSDictionary *record in NSThread.currentThread.threadDictionary[kImports]) {
        NSMutableDictionary *import = record.mutableCopy;
        if (record[@"url"]) {
            NSData *data = [NSData dataWithContentsOfURL:record[@"url"]];
            check(data.length > 0, @"Import resource stays alive until Photos reads it");
            import[@"data"] = data;
        }
        [imports addObject:import];
    }
    self.imports = imports;
    [NSThread.currentThread.threadDictionary removeObjectForKey:kImports];
    if (self.failImport && error) *error = [NSError errorWithDomain:@"TestPhotos" code:1 userInfo:nil];
    return !self.failImport;
}
@end

static void verifyImportedVideo(PHPhotoLibrary *library, NSURL *source, BOOL normalized) {
    NSDictionary *record = library.imports.firstObject;
    if (!normalized) {
        check([record[@"data"] isEqual:[NSData dataWithContentsOfURL:source]], @"Passthrough retains original bytes");
        return;
    }
    NSURL *url = [NSURL fileURLWithPath:[NSTemporaryDirectory()
        stringByAppendingPathComponent:[NSString stringWithFormat:@"TGExtraImportedTest-%@.mp4", NSUUID.UUID.UUIDString]]];
    [record[@"data"] writeToURL:url atomically:YES];
    AVURLAsset *asset = [AVURLAsset URLAssetWithURL:url options:nil];
    AVURLAsset *original = [AVURLAsset URLAssetWithURL:source options:nil];
    check(fabs([asset tracksWithMediaType:AVMediaTypeVideo].firstObject.nominalFrameRate - 30) < 0.01,
          @"Photos receives normalized 30 fps video");
    check(fabs(CMTimeGetSeconds(asset.duration) - CMTimeGetSeconds(original.duration)) < 0.08,
          @"Photos receives the original duration");
    if (record[@"url"]) {
        check(![record[@"url"] isEqual:source], @"Photos receives a separate export");
        check(![[NSFileManager defaultManager] fileExistsAtPath:[record[@"url"] path]],
              @"Export is removed after the transaction, including failure");
    }
    check([[NSFileManager defaultManager] fileExistsAtPath:source.path], @"Source remains available");
    [[NSFileManager defaultManager] removeItemAtURL:url error:NULL];
}

static void runSave(NSURL *source, NSInteger route, BOOL bypass, BOOL failure, BOOL wait) {
    bypassEnabled = bypass;
    BOOL expectsNormalization = TGExtraStoryVideoNeedsNormalization(source);
    PHPhotoLibrary *library = [PHPhotoLibrary new];
    library.failImport = failure;
    PHAssetResourceCreationOptions *options = [PHAssetResourceCreationOptions new];
    options.shouldMoveFile = YES;
    dispatch_block_t changes = ^{
        if (route == 0) [PHAssetChangeRequest creationRequestForAssetFromVideoAtFileURL:source];
        else if (route == 1) [[PHAssetCreationRequest new] addResourceWithType:PHAssetResourceTypeVideo
                                                                            fileURL:source options:options];
        else [[PHAssetCreationRequest new] addResourceWithType:PHAssetResourceTypeVideo
                                                         data:[NSData dataWithContentsOfURL:source] options:options];
    };
    if (wait) {
        NSError *error = nil;
        check([library performChangesAndWait:changes error:&error] == !failure, @"Synchronous result preserved");
        check((error != nil) == failure, @"Synchronous error preserved");
    } else {
        dispatch_semaphore_t done = dispatch_semaphore_create(0);
        __block NSInteger callbacks = 0;
        [library performChanges:changes completionHandler:^(BOOL success, NSError *error) {
            callbacks++;
            check(success == !failure && (error != nil) == failure, @"Asynchronous result preserved");
            dispatch_semaphore_signal(done);
        }];
        check(dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, 60 * NSEC_PER_SEC)) == 0,
              @"Asynchronous save finishes");
        check(callbacks == 1, @"Completion called exactly once");
    }
    verifyImportedVideo(library, source, expectsNormalization);
    check(options.shouldMoveFile, @"Caller's resource options stay unchanged");
    if (route == 1 && expectsNormalization) check(![library.imports.firstObject[@"move"] boolValue], @"Photos does not move temporary exports");
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        check(argc == 2, @"Fixture directory supplied");
        Method getter = class_getInstanceMethod(NSUserDefaults.class, @selector(boolForKey:));
        IMP original = method_getImplementation(getter);
        method_setImplementation(getter, imp_implementationWithBlock(^BOOL(id defaults, NSString *key) {
            if ([key isEqual:kDisableForwardRestriction]) return bypassEnabled;
            return ((BOOL (*)(id, SEL, NSString *))original)(defaults, @selector(boolForKey:), key);
        }));
        NSString *directory = [NSString stringWithUTF8String:argv[1]];
        NSURL *source = [NSURL fileURLWithPath:[directory stringByAppendingPathComponent:@"high-fps.mp4"]];
        dispatch_semaphore_t done = dispatch_semaphore_create(0);
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            @autoreleasepool {
                // No UIKit/controller exists, and saves start on a worker queue.
                for (NSInteger route = 0; route < 3; route++) {
                    runSave(source, route, YES, NO, NO);
                    runSave(source, route, NO, NO, NO);
                }
                NSURL *round = [NSURL fileURLWithPath:[directory stringByAppendingPathComponent:@"round-60-fps.mp4"]];
                for (NSInteger route = 0; route < 3; route++) {
                    runSave(round, route, YES, NO, NO);
                    runSave(round, route, NO, NO, NO);
                }
                runSave(source, 0, YES, YES, NO);
                runSave(source, 1, YES, NO, YES);
                runSave(source, 1, YES, YES, YES);
                NSURL *ordinary = [NSURL fileURLWithPath:[directory stringByAppendingPathComponent:@"silent.mp4"]];
                for (NSInteger route = 0; route < 3; route++) runSave(ordinary, route, YES, NO, NO);
                NSLog(@"PASS story and round video saves, three import routes, bypass independence and cleanup");
                dispatch_semaphore_signal(done);
            }
        });
        check(dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, 180 * NSEC_PER_SEC)) == 0,
              @"Save hook tests finish");
    }
    return 0;
}
