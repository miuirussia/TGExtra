#import "Headers.h"
#import "UI/Headers.h"
#import "VideoAudioExtractor.h"
#import "RoundVideoExport.h"
#import "../tgapiC/include/VideoConversion.h"

@interface NSObject (TGExtraRoundVideoAdjustments)
- (bool)sendAsTelescope;
@end

static NSDictionary *tgextraRoundVideoDescription(NSDictionary *dict, NSURL *output, double duration) {
    NSMutableDictionary *rewritten = [dict mutableCopy];
    for (NSString *key in @[@"asset", @"url", @"adjustments", @"isAnimation", @"document",
                           @"dimensions", @"duration", @"coverImage", @"previewImage", @"groupedId", @"stickers"]) {
        [rewritten removeObjectForKey:key];
    }
    id adjustments = TGExtraVideoAdjustments(@{
        @"originalSize": [NSValue valueWithCGSize:CGSizeMake(384, 384)],
        @"cropRect": [NSValue valueWithCGRect:CGRectMake(0, 0, 384, 384)],
        @"trimStart": @0, @"trimEnd": @(duration), @"preset": @7, @"sendAsTelescope": @YES
    });
    if ([adjustments respondsToSelector:@selector(sendAsTelescope)] && [adjustments sendAsTelescope]) {
        // Swiftgram consumes this before enqueueing: both its local message and
        // its upload carry instantRoundVideo, rather than an ordinary MP4 file.
        rewritten[@"type"] = @"video";
        rewritten[@"url"] = output.path;
        rewritten[@"dimensions"] = [NSValue valueWithCGSize:CGSizeMake(384, 384)];
        rewritten[@"duration"] = @(duration);
        rewritten[@"adjustments"] = adjustments;
    } else {
        rewritten[@"type"] = @"file";
        rewritten[@"tempFileUrl"] = output;
        rewritten[@"mimeType"] = @"video/mp4";
        rewritten[@"fileName"] = output.lastPathComponent;
    }
    return rewritten;
}

NSDictionary *tgextraRewriteToRound(id value, id editingContext) {
    if (![value isKindOfClass:NSDictionary.class]) return nil;
    NSDictionary *dict = value;
    if (![@[@"video", @"cameraVideo"] containsObject:dict[@"type"]]) return nil;
    AVAsset *asset = tgextraResolveAVAsset(dict);
    if (!asset) {
        customLog(@"Round video: could not resolve source asset (%@)", dict[@"type"]);
        return nil;
    }
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
    customLog(@"Round video: starting export (trim %.3f..%.3f)",
              CMTimeGetSeconds(range.start), CMTimeGetSeconds(CMTimeRangeGetEnd(range)));
    NSURL *output = TGExtraExportRoundVideo(asset, range);
    if (!output) return nil;
    AVURLAsset *exported = [AVURLAsset URLAssetWithURL:output options:nil];
    double duration = CMTimeGetSeconds(exported.duration);
    if (!isfinite(duration) || duration <= 0 || duration > 60.1) {
        customLog(@"Round video: invalid exported duration %.3f", duration);
        [NSFileManager.defaultManager removeItemAtURL:output error:NULL];
        return nil;
    }
    [TLParser registerRoundVideoUploadWithFileName:output.lastPathComponent duration:duration];
    NSMutableDictionary *rewritten = [tgextraRoundVideoDescription(dict, output, duration) mutableCopy];
    CGImageRef image = TGExtraCopyRoundVideoPreview(exported);
    if (image) {
        rewritten[@"previewImage"] = [UIImage imageWithCGImage:image];
        CGImageRelease(image);
    }
    TGExtraShowToast([TGExtraLocalization localizedStringForKey:@"VIDEO_TO_ROUND_SUCCESS"]);
    return rewritten;
}
