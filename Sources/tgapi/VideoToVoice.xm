// Video to Voice — send only the audio track of a picked video.
//
// Telegram builds outgoing media in Swift code that is `private` to
// LegacyMediaPickerUI, so there is nothing to hook there. What *is* reachable
// is the seam feeding it: +[TGMediaAssetsController resultSignalsForSelection
// Context:...] takes a `descriptionGenerator` block, and that block receives a
// plain NSDictionary describing each picked item. Rewriting that dictionary
// from {type: "video", asset: ...} to {type: "file", tempFileUrl: <m4a>} makes
// Telegram send our extracted audio instead of the video, using only public
// Objective-C surface.
//
// The dictionary rewrite alone gets the audio sent, but as a plain document:
// Telegram builds `.file` items with nothing but a filename attribute, and the
// voice flag lives in the `.Audio` attribute it never produces. So each
// extraction also measures the track and hands TLParser a duration and a
// waveform, which rewrites the outgoing messages.sendMedia at the MTProto layer
// into a real voice message.

#import <AVFoundation/AVFoundation.h>
#import <Photos/Photos.h>
#import <objc/runtime.h>
#import <objc/message.h>

#import "Headers.h"
#import "Logger/Logger.h"
#import "UI/Headers.h"

// Minimal redeclarations of LegacyComponents types. Everything is probed with
// -respondsToSelector: before use, so a host app that renamed or dropped a
// property degrades to "leave the video alone" rather than crashing.
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

// The preview overlay. Only two methods are hooked: -itemFocused:itemView:,
// which fires whenever the visible item changes, and -layoutSubviews.
@interface TGMediaPickerGalleryInterfaceView : UIView
@end

typedef id (^TGExtraDescriptionGenerator)(id, NSAttributedString *, NSString *, NSString *);

// Extraction runs on whatever queue Telegram assembled the item on, and that
// queue is blocked while it waits. A stuck AVFoundation export must not hang
// the send forever.
static const NSTimeInterval kTGExtraExtractionTimeout = 180.0;

static BOOL tgextraVideoToVoiceEnabled(void) {
    return [[NSUserDefaults standardUserDefaults] boolForKey:kVideoToVoice];
}

static const void *kTGExtraVoiceItemsKey = &kTGExtraVoiceItemsKey;
static const void *kTGExtraVoicePreviewItemKey = &kTGExtraVoicePreviewItemKey;

static id tgextraVoiceProperty(id object, NSString *name) {
    SEL selector = NSSelectorFromString(name);
    return [object respondsToSelector:selector]
        ? ((id (*)(id, SEL))objc_msgSend)(object, selector) : nil;
}

static NSString *tgextraVoiceItemIdentifier(id item) {
    item = tgextraVoiceProperty(item, @"editableMediaItem") ?: item;
    id identifier = tgextraVoiceProperty(item, @"uniqueIdentifier");
    if ([identifier isKindOfClass:NSString.class] && [identifier length]) return identifier;
    if ([item isKindOfClass:NSURL.class]) return [item absoluteString];
    if ([item isKindOfClass:NSString.class] && [item length]) {
        return [item hasPrefix:@"file://"] ? item : [NSURL fileURLWithPath:item].absoluteString;
    }
    return nil;
}

// Conversion choices belong to the picker's editing context, never to saved
// preferences. A new picker starts with no videos selected for conversion.
static NSSet<NSString *> *tgextraVoiceItems(id editingContext) {
    if (!editingContext) return [NSSet set];
    @synchronized(editingContext) {
        return [objc_getAssociatedObject(editingContext, kTGExtraVoiceItemsKey) copy] ?: [NSSet set];
    }
}

static BOOL tgextraToggleVoiceItem(id galleryItem) {
    id context = tgextraVoiceProperty(galleryItem, @"editingContext");
    NSString *identifier = tgextraVoiceItemIdentifier(galleryItem);
    if (!context || !identifier) return NO;
    @synchronized(context) {
        NSMutableSet *items = [tgextraVoiceItems(context) mutableCopy];
        BOOL enabled = ![items containsObject:identifier];
        if (enabled) [items addObject:identifier];
        else [items removeObject:identifier];
        objc_setAssociatedObject(context, kTGExtraVoiceItemsKey, items,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        return enabled;
    }
}

static NSString *tgextraVoiceCacheRoot(void) {
    return [NSTemporaryDirectory() stringByAppendingPathComponent:@"TGExtraVideoToVoice"];
}

// Every extraction gets a fresh directory and nothing is ever reused. Sending
// the same video twice therefore cannot pick up the previous run's file, which
// is what used to leave the second send stuck in the wrong mode.
//
// The file name carries a random suffix as well, because it is the only thing
// that identifies this extraction once the request reaches the MTProto layer —
// two clips called IMG_0740 would otherwise share one waveform.
static NSURL *tgextraNewOutputURL(NSString *baseName) {
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

// Number of bars Telegram draws in a voice bubble. Its own recorder produces
// 100 five-bit samples, and the drawing code scales whatever it gets to the
// bubble width, so matching that count keeps the bars the usual thickness.
static const NSInteger kTGExtraWaveformSamples = 100;

/// One 0…31 amplitude per bar, measured off the exported track.
///
/// Without this the document goes out with no waveform at all, and the bubble
/// falls back to a row of identical dots — every bar the minimum height,
/// because the drawing code reads an empty sample buffer and leaves every
/// bucket at zero.
static NSData *tgextraComputeWaveform(AVURLAsset *asset) {
    AVAssetTrack *track = [asset tracksWithMediaType:AVMediaTypeAudio].firstObject;
    if (!track) return nil;

    NSError *error = nil;
    AVAssetReader *reader = [[AVAssetReader alloc] initWithAsset:asset error:&error];
    if (!reader) {
        tgextraDiag("v2v: waveform reader failed — %{public}s",
                 error.localizedDescription.UTF8String ?: "unknown");
        return nil;
    }

    NSDictionary *settings = @{
        (id)AVFormatIDKey : @(kAudioFormatLinearPCM),
        (id)AVLinearPCMBitDepthKey : @16,
        (id)AVLinearPCMIsBigEndianKey : @NO,
        (id)AVLinearPCMIsFloatKey : @NO,
        (id)AVLinearPCMIsNonInterleavedKey : @NO,
    };
    AVAssetReaderTrackOutput *output =
        [[AVAssetReaderTrackOutput alloc] initWithTrack:track outputSettings:settings];
    if (![reader canAddOutput:output]) return nil;
    [reader addOutput:output];
    if (![reader startReading]) return nil;

    // Peaks are collected over small fixed windows first and only folded into
    // the 100 bars at the end. Bucketing straight away would need the total
    // frame count up front, and an estimate that came out high would leave the
    // tail of the waveform empty.
    static const size_t kWindow = 512;
    NSMutableData *windows = [NSMutableData data];
    uint32_t windowPeak = 0;
    size_t windowFill = 0;

    CMSampleBufferRef sample = NULL;
    while ((sample = [output copyNextSampleBuffer])) {
        CMBlockBufferRef block = CMSampleBufferGetDataBuffer(sample);
        if (block) {
            size_t length = CMBlockBufferGetDataLength(block);
            int16_t *frames = (int16_t *)malloc(length);
            if (frames) {
                if (CMBlockBufferCopyDataBytes(block, 0, length, frames) == kCMBlockBufferNoErr) {
                    size_t count = length / sizeof(int16_t);
                    for (size_t i = 0; i < count; i++) {
                        int32_t value = frames[i];
                        uint32_t magnitude = (uint32_t)(value < 0 ? -value : value);
                        if (magnitude > windowPeak) windowPeak = magnitude;
                        if (++windowFill == kWindow) {
                            [windows appendBytes:&windowPeak length:sizeof(windowPeak)];
                            windowPeak = 0;
                            windowFill = 0;
                        }
                    }
                }
                free(frames);
            }
        }
        CMSampleBufferInvalidate(sample);
        CFRelease(sample);
    }
    [reader cancelReading];
    if (windowFill > 0) {
        [windows appendBytes:&windowPeak length:sizeof(windowPeak)];
    }

    NSInteger windowCount = (NSInteger)(windows.length / sizeof(uint32_t));
    if (windowCount == 0) {
        tgextraDiag("v2v: no audio frames read — no waveform");
        return nil;
    }

    // Reading per bar rather than per window covers both directions: a long
    // clip folds many windows into one bar, and a clip shorter than the bar
    // count reuses windows instead of leaving gaps.
    const uint32_t *windowPeaks = (const uint32_t *)windows.bytes;
    uint32_t peaks[kTGExtraWaveformSamples];
    for (NSInteger bar = 0; bar < kTGExtraWaveformSamples; bar++) {
        NSInteger from = (bar * windowCount) / kTGExtraWaveformSamples;
        NSInteger to = ((bar + 1) * windowCount) / kTGExtraWaveformSamples;
        if (to <= from) to = from + 1;
        if (to > windowCount) to = windowCount;
        uint32_t peak = 0;
        for (NSInteger i = from; i < to; i++) {
            if (windowPeaks[i] > peak) peak = windowPeaks[i];
        }
        peaks[bar] = peak;
    }

    uint32_t loudest = 0;
    for (NSInteger i = 0; i < kTGExtraWaveformSamples; i++) {
        if (peaks[i] > loudest) loudest = peaks[i];
    }
    if (loudest == 0) {
        tgextraDiag("v2v: track is silent — no waveform");
        return nil;
    }

    // Scaled against the loudest bar rather than against full scale, so a
    // quietly recorded clip still fills the bubble instead of drawing a flat
    // line near the bottom.
    NSMutableData *result = [NSMutableData dataWithLength:kTGExtraWaveformSamples];
    uint8_t *bars = (uint8_t *)result.mutableBytes;
    for (NSInteger i = 0; i < kTGExtraWaveformSamples; i++) {
        bars[i] = (uint8_t)((peaks[i] * 31 + loudest / 2) / loudest);
    }
    return result;
}

/// Resolves the AVAsset behind a picker dictionary, waiting for iCloud if need be.
static AVAsset *tgextraResolveAVAsset(NSDictionary *dict) {
    id asset = dict[@"asset"];
    if ([asset respondsToSelector:@selector(backingAsset)]) {
        PHAsset *backing = [asset backingAsset];
        if (![backing isKindOfClass:[PHAsset class]]) return nil;

        PHVideoRequestOptions *options = [[PHVideoRequestOptions alloc] init];
        options.networkAccessAllowed = YES;
        options.deliveryMode = PHVideoRequestOptionsDeliveryModeHighQualityFormat;
        options.version = PHVideoRequestOptionsVersionCurrent;

        __block AVAsset *resolved = nil;
        dispatch_semaphore_t done = dispatch_semaphore_create(0);
        [[PHImageManager defaultManager]
            requestAVAssetForVideo:backing
                           options:options
                     resultHandler:^(AVAsset *avAsset, AVAudioMix *mix, NSDictionary *info) {
                         resolved = avAsset;
                         dispatch_semaphore_signal(done);
                     }];
        dispatch_semaphore_wait(
            done, dispatch_time(DISPATCH_TIME_NOW,
                                (int64_t)(kTGExtraExtractionTimeout * NSEC_PER_SEC)));
        return resolved;
    }

    // Camera captures and already-exported clips arrive as a path instead.
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

/// Reads the preview's trim handles, if the user moved them.
static CMTimeRange tgextraTrimRange(id editingContext, id item, AVAsset *asset) {
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

/// Exports the audio track as m4a. Returns nil and leaves the video untouched
/// on any failure, including a video that has no audio at all.
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

    // Measure the file that was actually written, not the source: the trim has
    // been applied by now, so this is the duration and the shape the recipient
    // will see.
    AVURLAsset *exported = [AVURLAsset URLAssetWithURL:output options:nil];
    NSInteger duration = (NSInteger)llround(CMTimeGetSeconds(exported.duration));
    if (duration < 1) duration = 1;
    NSData *waveform = tgextraComputeWaveform(exported);
    [TLParser registerVoiceUploadWithFileName:output.lastPathComponent
                                     duration:duration
                                     waveform:waveform];
    tgextraDiag("v2v: registered %{public}s duration=%ld waveform=%ld bars",
             output.lastPathComponent.UTF8String, (long)duration,
             (long)waveform.length);

    TGExtraShowToast([TGExtraLocalization localizedStringForKey:@"VIDEO_TO_VOICE_SUCCESS"]);
    return output;
}

/// Turns a video item description into an audio-file item description.
/// Returns nil when the item is not a video we can handle, meaning "send as-is".
static NSDictionary *tgextraRewriteToVoice(id anyDict, id editingContext) {
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
    // Keys that only mean something for a video would otherwise steer the
    // generator back into its video branch.
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

// ============================================================
// The toggle, in the video preview itself.
//
// The TGExtra setting controls availability. This button opts an individual
// video into conversion without changing that persistent setting.
//
// Placed beneath Telegram's selection checkmark, away from the bottom toolbar
// and Swiftgram's round-video button.
// ============================================================

#define kTGExtraVoiceButtonTag 8877
static const CGFloat kTGExtraVoiceButtonSide = 44.0;

static const void *kTGExtraItemIsVideoKey = &kTGExtraItemIsVideoKey;

/// True for a picked video. Fetch-result items wrap the real one, so the
/// backing item is checked too.
static BOOL tgextraItemIsVideo(id item) {
    if (!item) return NO;
    if ([NSStringFromClass([item class]) containsString:@"Video"]) return YES;

    SEL backing = NSSelectorFromString(@"backingItem");
    if ([item respondsToSelector:backing]) {
        id inner = ((id (*)(id, SEL))objc_msgSend)(item, backing);
        if (inner) return [NSStringFromClass([inner class]) containsString:@"Video"];
    }
    return NO;
}

static void tgextraStyleVoiceButton(UIButton *button, BOOL enabled) {
    UIImage *icon = [UIImage systemImageNamed:@"waveform"];
    UIImageSymbolConfiguration *cfg =
        [UIImageSymbolConfiguration configurationWithPointSize:18
                                                        weight:UIImageSymbolWeightSemibold];
    if (cfg && icon) icon = [icon imageByApplyingSymbolConfiguration:cfg];
    [button setImage:icon forState:UIControlStateNormal];
    button.tintColor = [UIColor whiteColor];
    button.backgroundColor = enabled ? [UIColor systemBlueColor]
                                     : [UIColor colorWithWhite:0.0 alpha:0.5];
}

@interface TGExtraVoiceToggleTarget : NSObject
+ (instancetype)shared;
@end

@implementation TGExtraVoiceToggleTarget

+ (instancetype)shared {
    static TGExtraVoiceToggleTarget *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ instance = [self new]; });
    return instance;
}

- (void)handleTap:(UIButton *)sender {
    if (!tgextraVideoToVoiceEnabled()) return;
    id item = objc_getAssociatedObject(sender, kTGExtraVoicePreviewItemKey);
    BOOL enabled = tgextraToggleVoiceItem(item);
    tgextraStyleVoiceButton(sender, enabled);
    sender.accessibilityValue = [TGExtraLocalization localizedStringForKey:
        enabled ? @"VIDEO_TO_VOICE_ON_TOAST" : @"VIDEO_TO_VOICE_OFF_TOAST"];
    tgextraDiag("v2v: preview toggle -> %d", enabled);

    TGExtraShowToast([TGExtraLocalization localizedStringForKey:
        enabled ? @"VIDEO_TO_VOICE_ON_TOAST" : @"VIDEO_TO_VOICE_OFF_TOAST"]);

    UIImpactFeedbackGenerator *haptic = [[UIImpactFeedbackGenerator alloc]
        initWithStyle:UIImpactFeedbackStyleMedium];
    [haptic impactOccurred];
}

@end

static UIView *tgextraFindSubviewByClassSubstring(UIView *root, NSString *needle, int depth) {
    if (!root || depth > 6) return nil;
    for (UIView *sub in root.subviews) {
        if ([NSStringFromClass([sub class]) containsString:needle]) return sub;
        UIView *found = tgextraFindSubviewByClassSubstring(sub, needle, depth + 1);
        if (found) return found;
    }
    return nil;
}

/// Where the button goes.
///
/// Two attempts got this wrong before the source settled it.
///
/// The first placed it at the view's own safeAreaInsets, which come back as
/// zero — the gallery lays its overlay out against insets the controller hands
/// it, not against the view hierarchy — so the button landed under the Dynamic
/// Island and could not be tapped.
///
/// The second mirrored Telegram's selection checkmark onto the opposite edge.
/// That reads well in portrait and is exactly backwards in landscape: the
/// checkmark sits opposite the landscape toolbar, which fills a whole side
/// edge, so "the other side" is precisely the side that is already occupied.
/// Rotating the phone dropped the button on top of the toolbar.
///
/// So: the checkmark's own side, directly below it. That corner is the one
/// Telegram keeps clear in every orientation — the toolbar, the photo counter
/// and the selected-photos strip all cluster on the far side of it.
static CGRect tgextraVoiceButtonFrame(UIView *interfaceView) {
    CGFloat side = kTGExtraVoiceButtonSide;
    UIWindow *window = interfaceView.window;
    CGRect bounds = interfaceView.bounds;

    UIEdgeInsets safe = interfaceView.safeAreaInsets;
    if (safe.top < 1.0 && window) safe = window.safeAreaInsets;

    // Only reached if the checkmark is gone; the corner opposite the portrait
    // toolbar is the least bad guess.
    CGFloat x = bounds.size.width - safe.right - 8.0 - side;
    CGFloat y = safe.top + 5.0 + side + 8.0;

    UIView *check = tgextraFindSubviewByClassSubstring(interfaceView, @"CheckButton", 0);
    if (check && !check.hidden && check.bounds.size.height > 0) {
        CGRect frame = [interfaceView convertRect:check.bounds fromView:check];
        x = CGRectGetMidX(frame) - side / 2.0;
        y = CGRectGetMaxY(frame) + 8.0;
    }

    // Whatever the two paths above decided, the result still has to be inside
    // the window's safe area — an overlay taller than the screen would push a
    // perfectly reasonable local coordinate up behind the status bar.
    if (window) {
        CGPoint inWindow = [interfaceView convertPoint:CGPointMake(x, y) toView:window];
        CGFloat minY = window.safeAreaInsets.top + 5.0;
        if (inWindow.y < minY) y += (minY - inWindow.y);
    }

    // And inside the view, so a checkmark near an edge cannot push it off.
    x = MAX(safe.left + 8.0, MIN(x, bounds.size.width - safe.right - 8.0 - side));
    y = MAX(safe.top + 5.0, MIN(y, bounds.size.height - safe.bottom - 8.0 - side));

    return CGRectMake(x, y, side, side);
}

/// Creates the button on first use and keeps its position and state current.
/// Called from -layoutSubviews, so it runs again on every rotation and on every
/// caption-panel resize.
static void tgextraUpdateVoiceButton(UIView *interfaceView) {
    if (!interfaceView) return;

    BOOL isVideo = [objc_getAssociatedObject(interfaceView, kTGExtraItemIsVideoKey) boolValue];
    UIButton *button = (UIButton *)[interfaceView viewWithTag:kTGExtraVoiceButtonTag];

    id item = objc_getAssociatedObject(interfaceView, kTGExtraVoicePreviewItemKey);
    id context = tgextraVoiceProperty(item, @"editingContext");
    NSString *identifier = tgextraVoiceItemIdentifier(item);
    if (!tgextraVideoToVoiceEnabled() || !isVideo || !context || !identifier) {
        button.hidden = YES;
        return;
    }

    if (!button) {
        button = [UIButton buttonWithType:UIButtonTypeSystem];
        button.tag = kTGExtraVoiceButtonTag;
        button.layer.cornerRadius = kTGExtraVoiceButtonSide / 2.0;
        button.clipsToBounds = YES;
        [button addTarget:[TGExtraVoiceToggleTarget shared]
                   action:@selector(handleTap:)
         forControlEvents:UIControlEventTouchUpInside];
        [interfaceView addSubview:button];
    }

    objc_setAssociatedObject(button, kTGExtraVoicePreviewItemKey, item,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    BOOL enabled = [tgextraVoiceItems(context) containsObject:identifier];
    button.accessibilityLabel = [TGExtraLocalization localizedStringForKey:@"VIDEO_TO_VOICE_TITLE"];
    button.accessibilityValue = [TGExtraLocalization localizedStringForKey:
        enabled ? @"VIDEO_TO_VOICE_ON_TOAST" : @"VIDEO_TO_VOICE_OFF_TOAST"];
    button.hidden = NO;
    tgextraStyleVoiceButton(button, enabled);
    button.frame = tgextraVoiceButtonFrame(interfaceView);
    [interfaceView bringSubviewToFront:button];

#if TGEXTRA_DIAG
    // Printed once per placement decision, not per layout pass — layoutSubviews
    // runs on every scrub of the trim handles.
    static CGRect lastFrame = {{0, 0}, {0, 0}};
    if (!CGRectEqualToRect(lastFrame, button.frame)) {
        lastFrame = button.frame;
        UIEdgeInsets viewSafe = interfaceView.safeAreaInsets;
        UIEdgeInsets winSafe = interfaceView.window.safeAreaInsets;
        tgextraDiag("v2v: button at %.0f,%.0f — viewSafeTop=%.0f windowSafeTop=%.0f",
                 button.frame.origin.x, button.frame.origin.y,
                 viewSafe.top, winSafe.top);
    }
#endif
}

%group TGExtraVoicePreview
%hook TGMediaPickerGalleryInterfaceView

- (void)itemFocused:(id)item itemView:(id)itemView {
    %orig;
    objc_setAssociatedObject(self, kTGExtraItemIsVideoKey, @(tgextraItemIsVideo(item)),
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(self, kTGExtraVoicePreviewItemKey, item,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    tgextraUpdateVoiceButton(self);
}

- (void)layoutSubviews {
    %orig;
    tgextraUpdateVoiceButton(self);
}

// The overlay answers -hitTest: from an explicit allow-list of its own controls
// and returns nil for everything else, so the rest of the screen stays
// transparent to touches and the gallery underneath receives them. A subview
// added from outside is not on that list: the button drew fine and swallowed
// nothing, because every touch on it was handed straight past.
//
// Only points genuinely inside the button are claimed here; everything else
// goes to the original.
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    UIButton *button = (UIButton *)[self viewWithTag:kTGExtraVoiceButtonTag];
    if (button && !button.hidden && button.alpha > 0.01) {
        if ([button pointInside:[self convertPoint:point toView:button] withEvent:event]) {
            return button;
        }
    }
    return %orig;
}

%end
%end

%group TGExtraVoiceSend
%hook TGMediaAssetsController

+ (NSArray *)resultSignalsForSelectionContext:(id)selectionContext
                               editingContext:(id)editingContext
                                       intent:(NSInteger)intent
                                  currentItem:(id)currentItem
                                  storeAssets:(bool)storeAssets
                                convertToJpeg:(bool)convertToJpeg
                         descriptionGenerator:(TGExtraDescriptionGenerator)descriptionGenerator
                             saveEditedPhotos:(bool)saveEditedPhotos {
    if (!tgextraVideoToVoiceEnabled() || !descriptionGenerator) return %orig;

    NSSet<NSString *> *voiceItems = tgextraVoiceItems(editingContext);
    if (voiceItems.count == 0) return %orig;
    TGExtraDescriptionGenerator wrapped =
        ^id(id dict, NSAttributedString *caption, NSString *hash, NSString *uniqueId) {
            NSString *identifier = uniqueId;
            if (!identifier && [dict isKindOfClass:NSDictionary.class]) {
                identifier = tgextraVoiceItemIdentifier(dict[@"asset"] ?: dict[@"url"]);
            }
            if (!identifier || ![voiceItems containsObject:identifier]) {
                return descriptionGenerator(dict, caption, hash, uniqueId);
            }
            NSDictionary *rewritten = nil;
            @try {
                rewritten = tgextraRewriteToVoice(dict, editingContext);
            } @catch (NSException *e) {
                tgextraDiag("v2v: rewrite threw — %{public}s", e.reason.UTF8String ?: "?");
            }
            return descriptionGenerator(rewritten ?: dict, caption, hash, uniqueId);
        };

    return %orig(selectionContext, editingContext, intent, currentItem, storeAssets,
                 convertToJpeg, wrapped, saveEditedPhotos);
}

%end
%end

%ctor {
    // Deleting the leftovers is disk work, and a tweak constructor runs inside
    // dyld — before the app has drawn a single frame. Nothing needs the folder
    // gone until the user actually picks a video, so it happens off the launch
    // path. Anything left in there belongs to a previous launch, so no upload
    // can still be reading it.
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        [[NSFileManager defaultManager] removeItemAtPath:tgextraVoiceCacheRoot() error:nil];
    });

    Class cls = objc_getClass("TGMediaAssetsController");
    if (!cls) {
        tgextraDiag("v2v: TGMediaAssetsController absent — feature inert in this app");
        return;
    }

    // Reported separately: the preview toggle can be missing while the send
    // path still works, and a silently absent button is otherwise indis-
    // tinguishable from one that never got laid out.
    if (!objc_getClass("TGMediaPickerGalleryInterfaceView")) {
        tgextraDiag("v2v: TGMediaPickerGalleryInterfaceView absent — no preview button");
    }

#if TGEXTRA_DIAG
    // The hook below pins one exact selector. If the host app ships a different
    // arity, %hook silently does nothing, so list what is actually there —
    // that turns a silent no-op into a one-line answer in the log. Diagnostic
    // only: copying the method list is not worth doing on every launch.
    unsigned int count = 0;
    Method *methods = class_copyMethodList(object_getClass(cls), &count);
    BOOL matched = NO;
    for (unsigned int i = 0; i < count; i++) {
        NSString *name = NSStringFromSelector(method_getName(methods[i]));
        if (![name hasPrefix:@"resultSignalsForSelectionContext:"]) continue;
        matched = YES;
        tgextraDiag("v2v: found %{public}s", name.UTF8String);
    }
    free(methods);
    if (!matched) {
        tgextraDiag("v2v: no resultSignalsForSelectionContext: on TGMediaAssetsController");
    }
#endif

    Method send = class_getClassMethod(cls, NSSelectorFromString(@"resultSignalsForSelectionContext:editingContext:intent:currentItem:storeAssets:convertToJpeg:descriptionGenerator:saveEditedPhotos:"));
    if (send && method_getNumberOfArguments(send) == 10) { %init(TGExtraVoiceSend); }
    Class preview = objc_getClass("TGMediaPickerGalleryInterfaceView");
    Method focus = class_getInstanceMethod(preview, @selector(itemFocused:itemView:));
    if (focus && method_getNumberOfArguments(focus) == 4 &&
        class_getInstanceMethod(preview, @selector(layoutSubviews)) &&
        class_getInstanceMethod(preview, @selector(hitTest:withEvent:))) {
        %init(TGExtraVoicePreview);
    }
}
