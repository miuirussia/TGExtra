#import "AudioWaveform.h"
#import "Logger/Logger.h"

enum { kTGExtraWaveformSamples = 100 };

@interface TGExtraWaveformTask : NSObject
@property(nonatomic) BOOL cancelled;
@property(nonatomic, strong) NSData *waveform;
@end
@implementation TGExtraWaveformTask
@end

static NSData *tgextraReadAudioWaveform(AVURLAsset *asset, TGExtraWaveformTask *task) {
    AVAssetTrack *track = [asset tracksWithMediaType:AVMediaTypeAudio].firstObject;
    if (!track) return nil;

    NSError *error = nil;
    AVAssetReader *reader = [[AVAssetReader alloc] initWithAsset:asset error:&error];
    if (!reader) {
        tgextraDiag("v2v: waveform reader failed — %{public}s",
                 error.localizedDescription.UTF8String ?: "unknown");
        return nil;
    }
    @synchronized(task) {
        if (task.cancelled) return nil;
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

    static const size_t kWindow = 512;
    NSMutableData *windows = [NSMutableData data];
    uint32_t windowPeak = 0;
    size_t windowFill = 0;

    CMSampleBufferRef sample = NULL;
    while (YES) {
        @synchronized(task) { if (task.cancelled) break; }
        sample = [output copyNextSampleBuffer];
        if (!sample) break;
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

    NSMutableData *result = [NSMutableData dataWithLength:kTGExtraWaveformSamples];
    uint8_t *bars = (uint8_t *)result.mutableBytes;
    for (NSInteger i = 0; i < kTGExtraWaveformSamples; i++) {
        bars[i] = (uint8_t)((peaks[i] * 31 + loudest / 2) / loudest);
    }
    return result;
}

static NSData *tgextraAudioWaveformWithTimeout(AVURLAsset *asset, NSTimeInterval timeout) {
    // If a decoder stays blocked, subsequent sends skip the optional
    // waveform instead of accumulating blocked workers or queued assets.
    static dispatch_semaphore_t available;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ available = dispatch_semaphore_create(1); });
    if (dispatch_semaphore_wait(available, DISPATCH_TIME_NOW) != 0) return nil;

    TGExtraWaveformTask *task = [TGExtraWaveformTask new];
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        @try {
            @autoreleasepool {
                NSData *waveform = tgextraReadAudioWaveform(asset, task);
                @synchronized(task) { if (!task.cancelled) task.waveform = waveform; }
            }
        } @catch (NSException *exception) {
            customLog(@"Video to voice: waveform failed — %@", exception.reason);
        } @finally {
            dispatch_semaphore_signal(available);
            dispatch_semaphore_signal(done);
        }
    });
    if (dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW,
            (int64_t)(timeout * NSEC_PER_SEC))) != 0) {
        @synchronized(task) {
            task.cancelled = YES;
            task.waveform = nil;
        }
        // cancelReading cannot run concurrently with copyNextSampleBuffer.
        // The worker cancels between reads; the caller can already send the audio.
        customLog(@"Video to voice: waveform timed out — sending without a waveform");
        return nil;
    }
    @synchronized(task) { return task.waveform; }
}

NSData *TGExtraAudioWaveform(AVURLAsset *asset) {
    return tgextraAudioWaveformWithTimeout(asset, 5.0);
}
