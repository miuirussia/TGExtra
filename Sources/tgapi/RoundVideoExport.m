#import "RoundVideoExport.h"
#import "Logger/Logger.h"

static BOOL tgextraWaitForRoundExport(AVAssetExportSession *export, dispatch_semaphore_t done,
                                     NSTimeInterval timeout, NSTimeInterval stallTimeout) {
    NSTimeInterval started = NSProcessInfo.processInfo.systemUptime;
    NSTimeInterval advanced = started;
    float progress = 0;
    NSTimeInterval interval = MIN(1.0, stallTimeout);
    while (dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW,
               (int64_t)(interval * NSEC_PER_SEC))) != 0) {
        NSTimeInterval now = NSProcessInfo.processInfo.systemUptime;
        float current = export.progress;
        if (current > progress) {
            progress = current;
            advanced = now;
        }
        if (now - started >= timeout || now - advanced >= stallTimeout) {
            customLog(@"Round video: export timed out (status %ld, progress %.3f)",
                      (long)export.status, current);
            return NO;
        }
    }
    return YES;
}

static CGImageRef tgextraCopyRoundPreview(AVAssetImageGenerator *generator, NSTimeInterval timeout) {
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    __block CGImageRef preview = NULL;
    __block BOOL abandoned = NO;
    [generator generateCGImagesAsynchronouslyForTimes:@[[NSValue valueWithCMTime:kCMTimeZero]]
        completionHandler:^(CMTime requested, CGImageRef image, CMTime actual,
                            AVAssetImageGeneratorResult result, NSError *error) {
            @synchronized(done) {
                if (!abandoned && result == AVAssetImageGeneratorSucceeded && image) {
                    preview = CGImageRetain(image);
                }
            }
            dispatch_semaphore_signal(done);
        }];
    if (dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW,
            (int64_t)(timeout * NSEC_PER_SEC))) != 0) {
        @synchronized(done) {
            abandoned = YES;
            if (preview) { CGImageRelease(preview); preview = NULL; }
        }
        [generator cancelAllCGImageGeneration];
        customLog(@"Round video: preview timed out — sending without a preview");
        return NULL;
    }
    return preview;
}

CGImageRef TGExtraCopyRoundVideoPreview(AVAsset *asset) {
    if (NSThread.isMainThread) return NULL;
    AVAssetImageGenerator *generator = [AVAssetImageGenerator assetImageGeneratorWithAsset:asset];
    generator.appliesPreferredTrackTransform = YES;
    generator.maximumSize = CGSizeMake(384, 384);
    return tgextraCopyRoundPreview(generator, 5.0);
}

NSURL *TGExtraExportRoundVideo(AVAsset *asset, CMTimeRange range) {
    if (NSThread.isMainThread) {
        customLog(@"Round video: export must run off the main thread");
        return nil;
    }
    AVAssetTrack *track = [asset tracksWithMediaType:AVMediaTypeVideo].firstObject;
    if (!track || !CMTIME_IS_NUMERIC(asset.duration)) {
        customLog(@"Round video: missing video track or invalid source duration");
        return nil;
    }
    range = CMTimeRangeGetIntersection(range, CMTimeRangeMake(kCMTimeZero, asset.duration));
    if (!CMTIMERANGE_IS_VALID(range) || !CMTIME_IS_NUMERIC(range.duration) ||
        CMTimeCompare(range.duration, kCMTimeZero) <= 0) {
        customLog(@"Round video: invalid or empty trim range");
        return nil;
    }
    range.duration = CMTimeMinimum(range.duration, CMTimeMake(60, 1));

    CGRect oriented = CGRectApplyAffineTransform((CGRect){CGPointZero, track.naturalSize},
                                                 track.preferredTransform);
    CGFloat side = MIN(oriented.size.width, oriented.size.height);
    if (!isfinite(side) || side <= 0) {
        customLog(@"Round video: invalid source dimensions");
        return nil;
    }
    CGFloat scale = 384.0 / side;
    CGAffineTransform transform = track.preferredTransform;
    transform = CGAffineTransformConcat(transform, CGAffineTransformMakeTranslation(
        -CGRectGetMinX(oriented) - (oriented.size.width - side) / 2.0,
        -CGRectGetMinY(oriented) - (oriented.size.height - side) / 2.0));
    transform = CGAffineTransformConcat(transform, CGAffineTransformMakeScale(scale, scale));

    AVMutableVideoCompositionLayerInstruction *layer =
        [AVMutableVideoCompositionLayerInstruction videoCompositionLayerInstructionWithAssetTrack:track];
    [layer setTransform:transform atTime:kCMTimeZero];
    AVMutableVideoCompositionInstruction *instruction = [AVMutableVideoCompositionInstruction videoCompositionInstruction];
    instruction.timeRange = CMTimeRangeMake(kCMTimeZero, asset.duration);
    instruction.layerInstructions = @[layer];
    AVMutableVideoComposition *composition = [AVMutableVideoComposition videoComposition];
    composition.instructions = @[instruction];
    composition.renderSize = CGSizeMake(384, 384);
    composition.frameDuration = CMTimeMake(1, 30);

    NSString *root = [NSTemporaryDirectory() stringByAppendingPathComponent:@"TGExtraVideoToRound"];
    // Pending Telegram uploads can outlive this process; preserve their source files.
    NSError *directoryError = nil;
    if (![NSFileManager.defaultManager createDirectoryAtPath:root withIntermediateDirectories:YES
                                                attributes:nil error:&directoryError]) {
        customLog(@"Round video: could not create export directory — %@", directoryError);
        return nil;
    }
    NSURL *output = [NSURL fileURLWithPath:[root stringByAppendingPathComponent:
        [NSString stringWithFormat:@"round-%@.mp4", NSUUID.UUID.UUIDString]]];
    AVAssetExportSession *export = [[AVAssetExportSession alloc] initWithAsset:asset
        presetName:AVAssetExportPreset640x480];
    if (!export || ![export.supportedFileTypes containsObject:AVFileTypeMPEG4]) {
        customLog(@"Round video: H.264/MP4 export preset unavailable");
        return nil;
    }
    export.outputURL = output;
    export.outputFileType = AVFileTypeMPEG4;
    export.videoComposition = composition;
    export.timeRange = range;
    export.metadata = @[];
    export.shouldOptimizeForNetworkUse = YES;
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    __block BOOL abandoned = NO;
    [export exportAsynchronouslyWithCompletionHandler:^{
        @synchronized(export) {
            if (abandoned || export.status != AVAssetExportSessionStatusCompleted) {
                [NSFileManager.defaultManager removeItemAtURL:output error:NULL];
            }
        }
        dispatch_semaphore_signal(done);
    }];
    if (!tgextraWaitForRoundExport(export, done, 180.0, 30.0)) {
        @synchronized(export) {
            abandoned = YES;
            [NSFileManager.defaultManager removeItemAtURL:output error:NULL];
        }
        [export cancelExport];
        return nil;
    }
    if (export.status != AVAssetExportSessionStatusCompleted) {
        customLog(@"Round video: export failed (status %ld) — %@", (long)export.status, export.error);
        return nil;
    }
    customLog(@"Round video: export completed");
    return output;
}
