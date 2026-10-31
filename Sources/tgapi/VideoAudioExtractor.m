#import "Headers.h"
#import "UI/Headers.h"
#import "VoiceSelection.h"
#import "VideoAudioExtractor.h"
#import <objc/message.h>
#import "AudioWaveform.h"
#import <Photos/Photos.h>

@interface TGMediaAsset : NSObject
@property (nonatomic, readonly) PHAsset *backingAsset;
@property (nonatomic, readonly) NSString *fileName;
@end

@interface TGVideoEditAdjustments : NSObject
@property (nonatomic, readonly) NSTimeInterval trimStartValue;
@property (nonatomic, readonly) NSTimeInterval trimEndValue;
- (bool)trimApplied;
@end

@interface TGMediaEditingContext : NSObject
- (id)adjustmentsForItem:(id)item;
@end

static const NSTimeInterval kTGExtraExtractionTimeout = 180.0;

static NSString *tgextraVoiceCacheRoot(void) {
    return [NSTemporaryDirectory() stringByAppendingPathComponent:@"TGExtraVideoToVoice"];
}

static NSURL *tgextraNewOutputURL(NSString *baseName) {
    // Telegram can still reference files from a previous process for pending uploads.
    NSString *dir = [tgextraVoiceCacheRoot()
        stringByAppendingPathComponent:[[NSUUID UUID] UUIDString]];
    NSError *error = nil;
    if (![[NSFileManager defaultManager] createDirectoryAtPath:dir
                                  withIntermediateDirectories:YES
                                                   attributes:nil
                                                        error:&error]) {
        tgextraDiag("v2v: cannot create output dir — %{public}s",
                 error.localizedDescription.UTF8String ?: "unknown");
        return nil;
    }
    NSString *stem = baseName.length ? [baseName stringByDeletingPathExtension] : @"voice";
    NSString *tag = [[[NSUUID UUID] UUIDString] substringToIndex:8];
    NSString *name = [NSString stringWithFormat:@"%@_%@.m4a", stem, tag];
    return [NSURL fileURLWithPath:[dir stringByAppendingPathComponent:name]];
}

static AVAsset *tgextraResolvePhotosVideo(PHAsset *backing, NSTimeInterval timeout) {
    PHVideoRequestOptions *options = [[PHVideoRequestOptions alloc] init];
    options.networkAccessAllowed = YES;
    options.deliveryMode = PHVideoRequestOptionsDeliveryModeHighQualityFormat;
    options.version = PHVideoRequestOptionsVersionCurrent;

    __block AVAsset *resolved = nil;
    __block BOOL finished = NO;
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    PHImageManager *manager = PHImageManager.defaultManager;
    PHImageRequestID request = [manager requestAVAssetForVideo:backing options:options
        resultHandler:^(AVAsset *avAsset, AVAudioMix *mix, NSDictionary *info) {
            @synchronized(done) {
                if (finished) return;
                finished = YES;
                resolved = avAsset;
            }
            dispatch_semaphore_signal(done);
        }];
    if (dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW,
            (int64_t)(timeout * NSEC_PER_SEC))) != 0) {
        @synchronized(done) {
            finished = YES;
            resolved = nil;
        }
        [manager cancelImageRequest:request];
        customLog(@"Video conversion: Photos asset request timed out");
        return nil;
    }
    @synchronized(done) { return resolved; }
}

AVAsset *tgextraResolveAVAsset(NSDictionary *dict) {
    id asset = dict[@"asset"];
    if ([asset respondsToSelector:@selector(backingAsset)]) {
        PHAsset *backing = [asset backingAsset];
        if (![backing isKindOfClass:[PHAsset class]]) return nil;
        return tgextraResolvePhotosVideo(backing, kTGExtraExtractionTimeout);
    }

    id rawURL = dict[@"url"];
    NSURL *url = nil;
    if ([rawURL isKindOfClass:[NSURL class]]) {
        url = rawURL;
    } else if ([rawURL isKindOfClass:[NSString class]]) {
        NSString *path = rawURL;
        url = [path hasPrefix:@"file://"] ? [NSURL URLWithString:path]
                                          : [NSURL fileURLWithPath:path];
    }
    if (!url) return nil;
    return [AVURLAsset URLAssetWithURL:url options:nil];
}

CMTimeRange tgextraTrimRange(id editingContext, id item, AVAsset *asset) {
    CMTimeRange full = CMTimeRangeMake(kCMTimeZero, asset.duration);
    if (![editingContext respondsToSelector:@selector(adjustmentsForItem:)] || !item) {
        return full;
    }

    id adjustments = nil;
    @try {
        adjustments = [editingContext adjustmentsForItem:item];
    } @catch (NSException *e) {
        return full;
    }
    if (![adjustments respondsToSelector:@selector(trimApplied)] ||
        ![adjustments respondsToSelector:@selector(trimStartValue)] ||
        ![adjustments respondsToSelector:@selector(trimEndValue)]) {
        return full;
    }
    if (![adjustments trimApplied]) return full;

    NSTimeInterval start = [adjustments trimStartValue];
    NSTimeInterval end = [adjustments trimEndValue];
    if (!(end > start)) return full;

    CMTime cmStart = CMTimeMakeWithSeconds(start, NSEC_PER_SEC);
    CMTime cmEnd = CMTimeMakeWithSeconds(end, NSEC_PER_SEC);
    tgextraDiag("v2v: trim %.2f..%.2f", start, end);
    return CMTimeRangeFromTimeToTime(cmStart, cmEnd);
}

static NSURL *tgextraExtractAudio(AVAsset *asset, CMTimeRange range, NSString *baseName) {
    if ([asset tracksWithMediaType:AVMediaTypeAudio].count == 0) {
        tgextraDiag("v2v: source has no audio track");
        TGExtraShowToast([TGExtraLocalization localizedStringForKey:@"VIDEO_TO_VOICE_NO_AUDIO"]);
        return nil;
    }

    NSURL *output = tgextraNewOutputURL(baseName);
    if (!output) return nil;

    AVAssetExportSession *session =
        [[AVAssetExportSession alloc] initWithAsset:asset
                                         presetName:AVAssetExportPresetAppleM4A];
    if (!session) {
        tgextraDiag("v2v: AppleM4A preset unavailable for this asset");
        return nil;
    }
    session.outputURL = output;
    session.outputFileType = AVFileTypeAppleM4A;
    session.timeRange = range;

    TGExtraShowToast([TGExtraLocalization localizedStringForKey:@"VIDEO_TO_VOICE_EXTRACTING"]);

    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    [session exportAsynchronouslyWithCompletionHandler:^{
        dispatch_semaphore_signal(done);
    }];
    if (dispatch_semaphore_wait(
            done, dispatch_time(DISPATCH_TIME_NOW,
                                (int64_t)(kTGExtraExtractionTimeout * NSEC_PER_SEC))) != 0) {
        tgextraDiag("v2v: export timed out");
        [session cancelExport];
        TGExtraShowToast([TGExtraLocalization localizedStringForKey:@"VIDEO_TO_VOICE_FAILED"]);
        return nil;
    }

    if (session.status != AVAssetExportSessionStatusCompleted) {
        tgextraDiag("v2v: export failed status=%ld err=%{public}s",
                 (long)session.status,
                 session.error.localizedDescription.UTF8String ?: "none");
        TGExtraShowToast([TGExtraLocalization localizedStringForKey:@"VIDEO_TO_VOICE_FAILED"]);
        return nil;
    }

    tgextraDiag("v2v: extracted to %{public}s", output.path.UTF8String);

    AVURLAsset *exported = [AVURLAsset URLAssetWithURL:output options:nil];
    NSInteger duration = (NSInteger)llround(CMTimeGetSeconds(exported.duration));
    if (duration < 1) duration = 1;
    NSData *waveform = TGExtraAudioWaveform(exported);
    [TLParser registerVoiceUploadWithFileName:output.lastPathComponent
                                     duration:duration
                                     waveform:waveform];
    tgextraDiag("v2v: registered %{public}s duration=%ld waveform=%ld bars",
             output.lastPathComponent.UTF8String, (long)duration,
             (long)waveform.length);

    TGExtraShowToast([TGExtraLocalization localizedStringForKey:@"VIDEO_TO_VOICE_SUCCESS"]);
    return output;
}

NSDictionary *tgextraRewriteToVoice(id anyDict, id editingContext) {
    if (![anyDict isKindOfClass:[NSDictionary class]]) return nil;
    NSDictionary *dict = anyDict;

    NSString *type = dict[@"type"];
    if (![type isKindOfClass:[NSString class]]) return nil;
    if (!([type isEqualToString:@"video"] || [type isEqualToString:@"cameraVideo"])) {
        return nil;
    }

    AVAsset *asset = tgextraResolveAVAsset(dict);
    if (!asset) {
        tgextraDiag("v2v: could not resolve AVAsset for type=%{public}s", type.UTF8String);
        return nil;
    }

    id item = dict[@"asset"];
    CMTimeRange range = tgextraTrimRange(editingContext, item, asset);

    NSString *baseName = nil;
    if ([item respondsToSelector:@selector(fileName)]) baseName = [item fileName];
    if (!baseName.length) baseName = dict[@"fileName"];

    NSURL *audioURL = tgextraExtractAudio(asset, range, baseName);
    if (!audioURL) return nil;

    NSMutableDictionary *rewritten = [dict mutableCopy];
    rewritten[@"type"] = @"file";
    rewritten[@"tempFileUrl"] = audioURL;
    rewritten[@"mimeType"] = @"audio/mp4";
    rewritten[@"fileName"] = audioURL.lastPathComponent;
    [rewritten removeObjectForKey:@"asset"];
    [rewritten removeObjectForKey:@"adjustments"];
    [rewritten removeObjectForKey:@"isAnimation"];
    [rewritten removeObjectForKey:@"document"];
    [rewritten removeObjectForKey:@"url"];
    [rewritten removeObjectForKey:@"dimensions"];
    [rewritten removeObjectForKey:@"duration"];
    [rewritten removeObjectForKey:@"coverImage"];
    return rewritten;
}
