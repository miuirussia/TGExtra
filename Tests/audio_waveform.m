#import "../Sources/tgapi/AudioWaveform.m"
#import <objc/runtime.h>
#include <stdatomic.h>

static atomic_int readMode;
static dispatch_semaphore_t readingStarted, releaseReading, cancellationCalled;
static IMP originalRead, originalCancel;

static CMSampleBufferRef testRead(id output, SEL selector) {
    int mode = atomic_exchange(&readMode, 0);
    if (mode == 1) {
        dispatch_semaphore_signal(readingStarted);
        dispatch_semaphore_wait(releaseReading, DISPATCH_TIME_FOREVER);
        return NULL;
    }
    if (mode == 2) [NSException raise:@"TestDecoderError" format:@"Decoder failed"];
    return ((CMSampleBufferRef (*)(id, SEL))originalRead)(output, selector);
}

static void testCancel(id reader, SEL selector) {
    dispatch_semaphore_signal(cancellationCalled);
    ((void (*)(id, SEL))originalCancel)(reader, selector);
}

static void check(BOOL condition, NSString *message) {
    if (!condition) { NSLog(@"FAIL %@", message); exit(1); }
}

static void verifyWaveform(NSData *waveform) {
    check(waveform.length == 100, @"Produce 100 waveform bars");
    const uint8_t *bars = waveform.bytes;
    for (NSUInteger i = 0; i < waveform.length; i++) check(bars[i] > 0 && bars[i] <= 31, @"Waveform bars use five-bit amplitudes");
}

int main(int argc, const char **argv) { @autoreleasepool {
    check(argc == 2, @"Supply fixtures");
    NSString *directory = @(argv[1]);
    AVURLAsset *asset = [AVURLAsset URLAssetWithURL:[NSURL fileURLWithPath:
        [directory stringByAppendingPathComponent:@"audio.wav"]] options:nil];
    AVURLAsset *silent = [AVURLAsset URLAssetWithURL:[NSURL fileURLWithPath:
        [directory stringByAppendingPathComponent:@"silent.wav"]] options:nil];
    verifyWaveform(TGExtraAudioWaveform(asset));
    check(TGExtraAudioWaveform(silent) == nil, @"Silent tracks have no waveform");

    readingStarted = dispatch_semaphore_create(0);
    releaseReading = dispatch_semaphore_create(0);
    cancellationCalled = dispatch_semaphore_create(0);
    Method read = class_getInstanceMethod(AVAssetReaderTrackOutput.class, @selector(copyNextSampleBuffer));
    Method cancel = class_getInstanceMethod(AVAssetReader.class, @selector(cancelReading));
    originalRead = method_setImplementation(read, (IMP)testRead);
    originalCancel = method_setImplementation(cancel, (IMP)testCancel);

    atomic_store(&readMode, 1);
    NSTimeInterval started = NSProcessInfo.processInfo.systemUptime;
    check(tgextraAudioWaveformWithTimeout(asset, 0.2) == nil, @"A stuck decoder returns without a waveform");
    check(NSProcessInfo.processInfo.systemUptime - started < 2, @"Sending is bounded by the waveform deadline");
    check(dispatch_semaphore_wait(readingStarted, DISPATCH_TIME_NOW) == 0, @"Simulate a decoder blocked inside sample reading");
    check(dispatch_semaphore_wait(cancellationCalled, DISPATCH_TIME_NOW) != 0,
          @"Never cancel an AVAssetReader concurrently with sample reading");
    // Simulate a decoder that stays blocked after the caller's deadline.
    for (int i = 0; i < 8; i++) check(tgextraAudioWaveformWithTimeout(asset, 0.2) == nil,
                                     @"Later sends skip waveform while a decoder is still blocked");
    check(NSProcessInfo.processInfo.systemUptime - started < 2, @"Repeated sends do not queue more blocked decoders");
    dispatch_semaphore_signal(releaseReading);
    check(dispatch_semaphore_wait(cancellationCalled, dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC)) == 0,
          @"Cancel the abandoned reader once its in-flight read returns");
    NSData *recovered = nil;
    NSTimeInterval deadline = NSProcessInfo.processInfo.systemUptime + 3;
    while (!recovered && NSProcessInfo.processInfo.systemUptime < deadline) {
        recovered = tgextraAudioWaveformWithTimeout(asset, 1);
        if (!recovered) [NSThread sleepForTimeInterval:0.001];
    }
    verifyWaveform(recovered);
    atomic_store(&readMode, 2);
    check(tgextraAudioWaveformWithTimeout(asset, 1) == nil, @"A decoder exception does not strand the caller");
    verifyWaveform(TGExtraAudioWaveform(asset));
    method_setImplementation(read, originalRead);
    method_setImplementation(cancel, originalCancel);
    puts("PASS waveform recovery: PCM amplitudes, silence, timeout, cancellation, bounded workers, late completion and retry");
} return 0; }
