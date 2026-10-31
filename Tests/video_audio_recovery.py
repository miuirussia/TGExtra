#!/usr/bin/env python3
"""Exercise production Photos resolution and export directories without UIKit."""
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parent.parent
audio = (ROOT / 'Sources/tgapi/VideoAudioExtractor.m').read_text()
helpers = audio[audio.index('static NSString *tgextraVoiceCacheRoot('):audio.index('CMTimeRange tgextraTrimRange(')]
round_source = (ROOT / 'Sources/tgapi/RoundVideoExport.m').read_text()
start = round_source.index('    NSString *root = [NSTemporaryDirectory()')
round_directory = round_source[start:round_source.index('    NSURL *output = ', start)]

support = r'''
#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>
#define customLog(...) ((void)0)
#define tgextraDiag(...) ((void)0)
static const NSTimeInterval kTGExtraExtractionTimeout = 0.02;
typedef int32_t PHImageRequestID;
enum { PHVideoRequestOptionsDeliveryModeHighQualityFormat = 1, PHVideoRequestOptionsVersionCurrent = 1 };
@interface PHAsset : NSObject @end
@implementation PHAsset @end
@interface TestMediaAsset : NSObject
@property PHAsset *backingAsset;
@end
@implementation TestMediaAsset @end
@interface PHVideoRequestOptions : NSObject
@property BOOL networkAccessAllowed;
@property NSInteger deliveryMode;
@property NSInteger version;
@end
@implementation PHVideoRequestOptions @end
@interface PHImageManager : NSObject
@property NSMutableDictionary *pending;
@property NSUInteger cancellations;
@property int32_t counter;
@property BOOL succeeds;
@property AVAsset *result;
@property (copy) void (^lastHandler)(AVAsset *, AVAudioMix *, NSDictionary *);
+ (instancetype)defaultManager;
- (PHImageRequestID)requestAVAssetForVideo:(PHAsset *)asset options:(PHVideoRequestOptions *)options
    resultHandler:(void (^)(AVAsset *, AVAudioMix *, NSDictionary *))handler;
- (void)cancelImageRequest:(PHImageRequestID)identifier;
@end
@implementation PHImageManager
+ (instancetype)defaultManager {
    static PHImageManager *manager;
    if (!manager) { manager = [PHImageManager new]; manager.pending = [NSMutableDictionary new]; }
    return manager;
}
- (PHImageRequestID)requestAVAssetForVideo:(PHAsset *)asset options:(PHVideoRequestOptions *)options
    resultHandler:(void (^)(AVAsset *, AVAudioMix *, NSDictionary *))handler {
    NSCAssert(options.networkAccessAllowed && options.deliveryMode == PHVideoRequestOptionsDeliveryModeHighQualityFormat &&
              options.version == PHVideoRequestOptionsVersionCurrent, @"Preserve Photos request quality and iCloud access");
    PHImageRequestID identifier = ++self.counter;
    self.lastHandler = handler;
    if (self.succeeds) handler(self.result, nil, @{});
    else self.pending[@(identifier)] = [handler copy];
    return identifier;
}
- (void)cancelImageRequest:(PHImageRequestID)identifier {
    NSCAssert(self.pending[@(identifier)], @"Cancel the exact outstanding request");
    self.cancellations++;
    void (^callback)(AVAsset *, AVAudioMix *, NSDictionary *) = self.pending[@(identifier)];
    [self.pending removeObjectForKey:@(identifier)];
    callback(nil, nil, @{}); // Photos may deliver cancellation synchronously.
}
@end
static NSString *testRoot;
static NSString *testTemporaryDirectory(void) { return testRoot; }
#define NSTemporaryDirectory testTemporaryDirectory
'''

tests = r'''
int main(void) { @autoreleasepool {
    testRoot = [@"/private/tmp" stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
    NSFileManager *manager = NSFileManager.defaultManager;
    for (NSString *directory in @[@"TGExtraVideoToRound", @"TGExtraVideoToVoice/previous-process"]) {
        NSString *path = [testRoot stringByAppendingPathComponent:directory];
        NSCAssert([manager createDirectoryAtPath:path withIntermediateDirectories:YES attributes:nil error:NULL], @"Prepare pending uploads");
        [@"pending upload" writeToFile:[path stringByAppendingPathComponent:@"pending.mp4"]
            atomically:YES encoding:NSUTF8StringEncoding error:NULL];
    }
    NSCAssert(prepareRoundDirectory(), @"Prepare round directory for a new send");
    NSURL *voice = tgextraNewOutputURL(@"clip.mp4");
    NSURL *anotherVoice = tgextraNewOutputURL(@"clip.mp4");
    NSCAssert(voice && anotherVoice && ![voice isEqual:anotherVoice], @"Voice exports get unique destinations");
    for (NSString *path in @[@"TGExtraVideoToRound/pending.mp4", @"TGExtraVideoToVoice/previous-process/pending.mp4"]) {
        NSCAssert([[NSString stringWithContentsOfFile:[testRoot stringByAppendingPathComponent:path]
            encoding:NSUTF8StringEncoding error:NULL] isEqual:@"pending upload"], @"New sends preserve previous-process upload files");
    }

    PHImageManager *photos = PHImageManager.defaultManager;
    TestMediaAsset *media = [TestMediaAsset new]; media.backingAsset = [PHAsset new];
    for (int i = 0; i < 3; i++) {
        NSCAssert(tgextraResolveAVAsset(@{@"asset": media}) == nil, @"Timed out resolution returns failure");
        NSCAssert(photos.pending.count == 0 && photos.cancellations == i + 1, @"No outstanding requests accumulate after timeouts");
    }
    void (^late)(AVAsset *, AVAudioMix *, NSDictionary *) = photos.lastHandler;
    __weak AVAsset *lateAsset;
    @autoreleasepool {
        AVAsset *asset = [AVMutableComposition composition]; lateAsset = asset;
        late(asset, nil, @{});
    }
    NSCAssert(lateAsset == nil, @"Ignore and release late results after cancellation");
    photos.succeeds = YES; photos.result = [AVMutableComposition composition];
    NSCAssert(tgextraResolveAVAsset(@{@"asset": media}) == photos.result, @"The next Photos request succeeds after cancellation");
    photos.result = nil;
    NSCAssert(tgextraResolveAVAsset(@{@"asset": media}) == nil && photos.pending.count == 0,
              @"A completed Photos error does not wait for the deadline or leave a request active");
    for (id url in @[[NSURL fileURLWithPath:@"/tmp/camera.mp4"], @"/tmp/camera.mp4", @"file:///tmp/camera.mp4"]) {
        AVURLAsset *asset = (AVURLAsset *)tgextraResolveAVAsset(@{@"url": url});
        NSCAssert([asset.URL.path isEqual:@"/tmp/camera.mp4"], @"Preserve camera URL and string handling");
    }
    [manager removeItemAtPath:testRoot error:NULL];
    puts("PASS media recovery: pending files, unique outputs, Photos timeout cancellation, late callbacks and retry");
} return 0; }
'''

with tempfile.TemporaryDirectory(prefix='tgextra-video-audio-recovery-') as directory:
    path = Path(directory)
    harness = path / 'tests.m'
    harness.write_text(support + helpers + 'static NSURL *prepareRoundDirectory(void) {\n' +
                       round_directory + '    return [NSURL fileURLWithPath:root];\n}\n' + tests)
    binary = path / 'tests'
    subprocess.run(['clang', '-fobjc-arc', '-Werror', '-Wno-deprecated-declarations',
                    '-framework', 'Foundation', '-framework', 'AVFoundation',
                    str(harness), '-o', str(binary)], check=True)
    subprocess.run([str(binary)], check=True, timeout=15)
