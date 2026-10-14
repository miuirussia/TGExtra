#import "StoryVideoExport.h"
#import <AVFoundation/AVFoundation.h>
#import "Logger/Logger.h"

BOOL TGExtraStoryVideoNeedsNormalization(NSURL *inputURL) {
    if (!inputURL.isFileURL) return NO;
    AVURLAsset *asset = [AVURLAsset URLAssetWithURL:inputURL options:nil];
    AVAssetTrack *track = [asset tracksWithMediaType:AVMediaTypeVideo].firstObject;
    // Keep ordinary 24/30/60 fps imports unchanged. Telegram story sources
    // can carry 120 fps, which Photos classifies as high-frame-rate video.
    return track.nominalFrameRate > 60.5;
}

NSURL *TGExtraExportStoryVideo(NSURL *inputURL) {
    if ([NSThread isMainThread] || !inputURL.isFileURL) return nil;

    AVURLAsset *asset = [AVURLAsset URLAssetWithURL:inputURL options:nil];
    if (![asset tracksWithMediaType:AVMediaTypeVideo].count) return nil;

    AVAssetExportSession *export = [[AVAssetExportSession alloc]
        initWithAsset:asset presetName:AVAssetExportPresetHighestQuality];
    if (!export || ![export.supportedFileTypes containsObject:AVFileTypeMPEG4]) return nil;

    NSURL *outputURL = [NSURL fileURLWithPath:[NSTemporaryDirectory()
        stringByAppendingPathComponent:[NSString stringWithFormat:@"TGExtraStory-%@.mp4",
                                       NSUUID.UUID.UUIDString]]];
    // Normalize frame timing before Photos imports the source. Render at
    // 30 fps while keeping presentation times, audio and the preferred
    // transform. This cannot undo slow motion already rendered into an
    // exported file; it only changes the encoding of the source timeline.
    AVMutableVideoComposition *composition =
        [AVMutableVideoComposition videoCompositionWithPropertiesOfAsset:asset];
    composition.sourceTrackIDForFrameTiming = kCMPersistentTrackID_Invalid;
    composition.frameDuration = CMTimeMake(1, 30);
    export.videoComposition = composition;
    export.metadata = @[];
    export.outputURL = outputURL;
    export.outputFileType = AVFileTypeMPEG4;
    export.shouldOptimizeForNetworkUse = YES;

    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    __block BOOL abandoned = NO;
    [export exportAsynchronouslyWithCompletionHandler:^{
        // Also remove partial output after cancellation; the timeout caller
        // must not race a still-running encoder when deleting its file.
        @synchronized (export) {
            if (abandoned || export.status != AVAssetExportSessionStatusCompleted) {
                [[NSFileManager defaultManager] removeItemAtURL:outputURL error:NULL];
            }
        }
        dispatch_semaphore_signal(done);
    }];
    if (dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW,
                                                  180 * NSEC_PER_SEC)) != 0) {
        @synchronized (export) {
            abandoned = YES;
            if (export.status == AVAssetExportSessionStatusCompleted) {
                [[NSFileManager defaultManager] removeItemAtURL:outputURL error:NULL];
            }
        }
        [export cancelExport];
        tgextraDiag("story export: timed out");
        return nil;
    }
    if (export.status != AVAssetExportSessionStatusCompleted) {
        tgextraDiag("story export: failed — %{public}@", export.error);
        return nil;
    }
    return outputURL;
}
