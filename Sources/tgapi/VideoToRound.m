#import "Headers.h"
#import "UI/Headers.h"
#import "VideoAudioExtractor.h"
#import "RoundVideoExport.h"

NSDictionary *tgextraRewriteToRound(id value, id editingContext) {
    if (![value isKindOfClass:NSDictionary.class]) return nil;
    NSDictionary *dict = value;
    if (![@[@"video", @"cameraVideo"] containsObject:dict[@"type"]]) return nil;
    AVAsset *asset = tgextraResolveAVAsset(dict);
    if (!asset) return nil;
    CMTimeRange range = tgextraTrimRange(editingContext, dict[@"asset"] ?: dict[@"url"], asset);
    // Camera clips carry their trim in the outgoing description, without a Photos asset.
    id adjustments = dict[@"adjustments"];
    if ([adjustments respondsToSelector:@selector(trimStartValue)] &&
        [adjustments respondsToSelector:@selector(trimEndValue)]) {
        double start = [[adjustments valueForKey:@"trimStartValue"] doubleValue];
        double end = [[adjustments valueForKey:@"trimEndValue"] doubleValue];
        if (isfinite(start) && isfinite(end) && end > start) {
            range = CMTimeRangeFromTimeToTime(CMTimeMakeWithSeconds(start, 600),
                                              CMTimeMakeWithSeconds(end, 600));
        }
    }
    TGExtraShowToast([TGExtraLocalization localizedStringForKey:@"VIDEO_TO_ROUND_CONVERTING"]);
    NSURL *output = TGExtraExportRoundVideo(asset, range);
    if (!output) return nil;
    AVURLAsset *exported = [AVURLAsset URLAssetWithURL:output options:nil];
    double duration = CMTimeGetSeconds(exported.duration);
    if (!isfinite(duration) || duration <= 0 || duration > 60.1) {
        [NSFileManager.defaultManager removeItemAtURL:output error:NULL];
        return nil;
    }
    [TLParser registerRoundVideoUploadWithFileName:output.lastPathComponent duration:duration];
    NSMutableDictionary *rewritten = [dict mutableCopy];
    rewritten[@"type"] = @"file";
    rewritten[@"tempFileUrl"] = output;
    rewritten[@"mimeType"] = @"video/mp4";
    rewritten[@"fileName"] = output.lastPathComponent;
    for (NSString *key in @[@"asset", @"url", @"adjustments", @"isAnimation", @"document",
                           @"dimensions", @"duration", @"coverImage", @"previewImage", @"groupedId", @"stickers"]) {
        [rewritten removeObjectForKey:key];
    }
    AVAssetImageGenerator *generator = [AVAssetImageGenerator assetImageGeneratorWithAsset:exported];
    generator.appliesPreferredTrackTransform = YES;
    CGImageRef image = [generator copyCGImageAtTime:kCMTimeZero actualTime:NULL error:NULL];
    if (image) {
        rewritten[@"previewImage"] = [UIImage imageWithCGImage:image];
        CGImageRelease(image);
    }
    TGExtraShowToast([TGExtraLocalization localizedStringForKey:@"VIDEO_TO_ROUND_SUCCESS"]);
    return rewritten;
}
