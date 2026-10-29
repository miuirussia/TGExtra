#import "AudioWaveform.h"
#import "Logger/Logger.h"

enum { kTGExtraWaveformSamples = 100 };

NSData *TGExtraAudioWaveform(AVURLAsset *asset) {
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
