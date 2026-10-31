#!/usr/bin/env python3
"""Exercise audio export failure/timeout cleanup, including a late callback."""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parent.parent
source = (root / 'Sources/tgapi/VideoAudioExtractor.m').read_text()
paths = source[source.index('static NSString *tgextraVoiceCacheRoot('):source.index('static AVAsset *tgextraResolvePhotosVideo(')]
export = source[source.index('static NSURL *tgextraExtractAudio('):source.index('NSDictionary *tgextraRewriteToVoice(')]
export = export.replace('AVAssetExportSession *', 'TestExport *').replace('[AVAssetExportSession alloc]', '[TestExport alloc]')
support = r'''
#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>
#define tgextraDiag(...) ((void)0)
static NSString *testRoot;
static NSString *testTemporaryDirectory(void) { return testRoot; }
#define NSTemporaryDirectory testTemporaryDirectory
static const NSTimeInterval kTGExtraExtractionTimeout = 0.01;
static void TGExtraShowToast(NSString *text) {}
static NSData *TGExtraAudioWaveform(AVAsset *asset) { return nil; }
@interface TGExtraLocalization : NSObject
+ (NSString *)localizedStringForKey:(NSString *)key;
@end
@implementation TGExtraLocalization
+ (NSString *)localizedStringForKey:(NSString *)key { return key; }
@end
@interface TLParser : NSObject
+ (void)registerVoiceUploadWithFileName:(NSString *)name duration:(NSInteger)duration waveform:(NSData *)waveform;
@end
@implementation TLParser
+ (void)registerVoiceUploadWithFileName:(NSString *)name duration:(NSInteger)duration waveform:(NSData *)waveform {}
@end
static NSInteger mode;
static NSURL *lastOutput;
@interface TestExport : NSObject
@property NSURL *outputURL;
@property AVFileType outputFileType;
@property CMTimeRange timeRange;
@property AVAssetExportSessionStatus status;
@property NSError *error;
@property (copy) dispatch_block_t completion;
- (instancetype)initWithAsset:(AVAsset *)asset presetName:(NSString *)preset;
- (void)exportAsynchronouslyWithCompletionHandler:(dispatch_block_t)completion;
- (void)cancelExport;
@end
@implementation TestExport
- (instancetype)initWithAsset:(AVAsset *)asset presetName:(NSString *)preset {
    return mode == 0 ? nil : [super init];
}
- (void)exportAsynchronouslyWithCompletionHandler:(dispatch_block_t)completion {
    lastOutput = self.outputURL;
    [@"partial export" writeToURL:self.outputURL atomically:YES encoding:NSUTF8StringEncoding error:NULL];
    self.status = mode == 1 ? AVAssetExportSessionStatusFailed :
        mode == 2 ? AVAssetExportSessionStatusExporting : AVAssetExportSessionStatusCompleted;
    if (mode == 1) completion();
    else self.completion = completion;
}
- (void)cancelExport {
    // An export may finish or write once more while cancellation is in flight.
    [@"late write" writeToURL:self.outputURL atomically:YES encoding:NSUTF8StringEncoding error:NULL];
    self.status = AVAssetExportSessionStatusCancelled;
    dispatch_block_t callback = self.completion;
    self.completion = nil;
    callback();
}
@end
@interface TestAsset : NSObject
- (NSArray *)tracksWithMediaType:(AVMediaType)type;
@end
@implementation TestAsset
- (NSArray *)tracksWithMediaType:(AVMediaType)type { return @[@1]; }
@end
'''
tests = r'''
int main(void) { @autoreleasepool {
    testRoot = [@"/private/tmp" stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
    NSFileManager *manager = NSFileManager.defaultManager;
    AVAsset *asset = (id)[TestAsset new];
    for (mode = 0; mode < 4; mode++) {
        NSCAssert(tgextraExtractAudio(asset, kCMTimeRangeZero, @"clip.mp4") == nil, @"Export errors do not produce an upload");
        NSCAssert([manager contentsOfDirectoryAtPath:tgextraVoiceCacheRoot() error:NULL].count == 0,
            @"Preset failure, export failure and timeout races leave no partial file or UUID directory");
    }
    [manager removeItemAtPath:testRoot error:NULL];
    puts("PASS audio export cleanup: unavailable preset, failed export, timeout and completion/cancellation races");
} return 0; }
'''
with tempfile.TemporaryDirectory(prefix='tgextra-audio-cleanup-') as directory:
    directory = Path(directory)
    main = directory / 'main.m'
    main.write_text(support + paths + export + tests)
    binary = directory / 'tests'
    subprocess.run(['clang', '-fobjc-arc', '-Werror', '-Wno-deprecated-declarations',
                    '-framework', 'Foundation', '-framework', 'AVFoundation', '-framework', 'CoreMedia',
                    str(main), '-o', str(binary)], check=True)
    subprocess.run([str(binary)], check=True, timeout=10)
