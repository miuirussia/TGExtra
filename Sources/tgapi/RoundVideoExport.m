#import "RoundVideoExport.h"
#import "Logger/Logger.h"

NSURL *TGExtraExportRoundVideo(AVAsset *asset, CMTimeRange range) {
    if (NSThread.isMainThread) return nil;
    AVAssetTrack *track = [asset tracksWithMediaType:AVMediaTypeVideo].firstObject;
    if (!track || !CMTIME_IS_NUMERIC(asset.duration)) return nil;
    range = CMTimeRangeGetIntersection(range, CMTimeRangeMake(kCMTimeZero, asset.duration));
    if (!CMTIMERANGE_IS_VALID(range) || !CMTIME_IS_NUMERIC(range.duration) ||
        CMTimeCompare(range.duration, kCMTimeZero) <= 0) return nil;
    range.duration = CMTimeMinimum(range.duration, CMTimeMake(60, 1));

    CGRect oriented = CGRectApplyAffineTransform((CGRect){CGPointZero, track.naturalSize},
                                                 track.preferredTransform);
    CGFloat side = MIN(oriented.size.width, oriented.size.height);
    if (!isfinite(side) || side <= 0) return nil;
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
    static dispatch_once_t once;
    dispatch_once(&once, ^{ [NSFileManager.defaultManager removeItemAtPath:root error:NULL]; });
    if (![NSFileManager.defaultManager createDirectoryAtPath:root withIntermediateDirectories:YES
                                                attributes:nil error:NULL]) return nil;
    NSURL *output = [NSURL fileURLWithPath:[root stringByAppendingPathComponent:
        [NSString stringWithFormat:@"round-%@.mp4", NSUUID.UUID.UUIDString]]];
    AVAssetExportSession *export = [[AVAssetExportSession alloc] initWithAsset:asset
        presetName:AVAssetExportPreset640x480];
    if (!export || ![export.supportedFileTypes containsObject:AVFileTypeMPEG4]) return nil;
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
    if (dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, 180 * NSEC_PER_SEC))) {
        @synchronized(export) {
            abandoned = YES;
            [NSFileManager.defaultManager removeItemAtURL:output error:NULL];
        }
        [export cancelExport];
        return nil;
    }
    if (export.status != AVAssetExportSessionStatusCompleted) {
        tgextraDiag("round export: failed — %{public}@", export.error);
        return nil;
    }
    return output;
}
