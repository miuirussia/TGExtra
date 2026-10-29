#import "Support/PaidMediaPhotoMocks.h"
#import "../Sources/tgapi/PaidMedia.h"

static NSUInteger scenario;
static BOOL importedVideo;
static PHAssetChangeRequest *createdRequest;
static NSURL *input;
static NSURL *converted;
static NSUInteger conversions, importAttempts;
static NSURL *importURL;
NSString *const PHPhotosErrorDomain = @"PHPhotosErrorDomain";

NSURL *TGExtraExportStoryVideo(NSURL *url) {
    NSCAssert(!NSThread.isMainThread, @"Conversion stays off the main thread");
    conversions++;
    if (scenario < 6) return nil;
    converted = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString]];
    [@"converted media" writeToURL:converted atomically:YES encoding:NSUTF8StringEncoding error:NULL];
    return converted;
}

@implementation PHObjectPlaceholder
@end

@implementation PHAssetChangeRequest
+ (instancetype)makeRequest:(NSURL *)url video:(BOOL)video {
    NSCAssert([[NSData dataWithContentsOfURL:url] length] > 0, @"Photos reads a live input file");
    importedVideo = video;
    importURL = url;
    importAttempts++;
    if (scenario == 2 || (scenario == 6 && importAttempts == 1)) return nil;
    createdRequest = [self new];
    // Simulate a video carrying an old embedded creation timestamp.
    createdRequest.creationDate = [NSDate dateWithTimeIntervalSince1970:946684800];
    if (scenario != 3) {
        createdRequest.placeholderForCreatedAsset = [PHObjectPlaceholder new];
        createdRequest.placeholderForCreatedAsset.localIdentifier = @"test-created-asset";
    }
    return createdRequest;
}
+ (instancetype)creationRequestForAssetFromVideoAtFileURL:(NSURL *)url { return [self makeRequest:url video:YES]; }
+ (instancetype)creationRequestForAssetFromImageAtFileURL:(NSURL *)url { return [self makeRequest:url video:NO]; }
@end

@implementation PHPhotoLibrary
+ (instancetype)sharedPhotoLibrary {
    static PHPhotoLibrary *library;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ library = [self new]; });
    return library;
}
- (void)performChanges:(dispatch_block_t)changes completionHandler:(void (^)(BOOL, NSError *))completion {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        changes();
        NSCAssert([NSFileManager.defaultManager fileExistsAtPath:importURL.path], @"Import file survives the Photos changes block");
        BOOL invalidResource = scenario == 4 || scenario == 8 || (scenario == 7 && importAttempts == 1);
        NSError *error = invalidResource ? [NSError errorWithDomain:PHPhotosErrorDomain code:3302 userInfo:nil] : nil;
        if (scenario == 9) error = [NSError errorWithDomain:PHPhotosErrorDomain code:3311 userInfo:nil];
        // In scenarios 2 and 3 the transaction reports success but creates no
        // asset. This must never become a 'Saved to Photos' notification.
        completion(!error && scenario != 5, error);
    });
}
@end

static void runScenario(void) {
    if (scenario == 10) {
        [NSFileManager.defaultManager removeItemAtURL:input error:NULL];
        puts("PASS Photos import: asset confirmation, current creation date, nil requests, empty transactions, errors and input lifetime");
        exit(0);
    }
    createdRequest = nil;
    converted = nil;
    conversions = importAttempts = 0;
    BOOL video = scenario != 1;
    TGExtraImportPaidMedia(input, video, ^(NSString *identifier, NSError *error) {
        dispatch_assert_queue(dispatch_get_main_queue());
        NSCAssert(importedVideo == video, @"Photo and video imports use their own creation request");
        NSCAssert([NSFileManager.defaultManager fileExistsAtPath:input.path], @"Caller owns the input through completion");
        if (scenario < 2 || scenario == 6 || scenario == 7) {
            NSCAssert([identifier isEqualToString:@"test-created-asset"] && !error, @"Success confirms an actual asset identifier");
            NSCAssert(fabs(createdRequest.creationDate.timeIntervalSinceNow) < 10,
                      @"Imported purchase appears under today's date, not an old embedded timestamp");
        } else {
            NSCAssert(!identifier && error, @"No creation request, no placeholder or a failed transaction cannot report success");
            if (scenario == 4) NSCAssert(error.code == 3302 && [error.domain isEqualToString:@"PHPhotosErrorDomain"],
                                         @"Keep Photos' original import error");
        }
        if (scenario == 6 || scenario == 7 || scenario == 8) {
            NSCAssert(conversions == 1 && importAttempts == 2, @"Incompatible video gets exactly one converted import retry");
            NSCAssert(![NSFileManager.defaultManager fileExistsAtPath:converted.path], @"Converted video is cleaned after Photos finishes");
        }
        if (scenario == 9) NSCAssert(conversions == 0 && error.code == 3311, @"Permission errors never trigger transcoding");
        scenario++;
        runScenario();
    });
}

int main(void) {
    @autoreleasepool {
        input = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString]];
        [@"test media" writeToURL:input atomically:YES encoding:NSUTF8StringEncoding error:NULL];
        dispatch_async(dispatch_get_main_queue(), ^{ runScenario(); });
        dispatch_main();
    }
}
