#!/usr/bin/env python3
"""Verify the trim handed to audio export by the production voice rewriter."""
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parent.parent
source = (ROOT / 'Sources/tgapi/VideoAudioExtractor.m').read_text()
trim = source[source.index('CMTimeRange tgextraTrimRange('):source.index('static NSURL *tgextraExtractAudio(')]
rewrite = source[source.index('NSDictionary *tgextraRewriteToVoice('):source.index('BOOL TGExtraIsAudioFile(')]
support = r'''
#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>
#define tgextraDiag(...) ((void)0)
@interface TestAdjustments : NSObject
@property double trimStartValue;
@property double trimEndValue;
@property BOOL trimApplied;
@end
@implementation TestAdjustments @end
@interface TestContext : NSObject
@property id adjustments;
- (id)adjustmentsForItem:(id)item;
@end
@implementation TestContext
- (id)adjustmentsForItem:(id)item { return self.adjustments; }
@end
@interface NSObject (TestFileName)
- (NSString *)fileName;
@end
@interface TestAsset : AVAsset @end
@implementation TestAsset
- (CMTime)duration { return CMTimeMake(10, 1); }
@end
static CMTimeRange exportedRange;
static AVAsset *tgextraResolveAVAsset(NSDictionary *dict) { return [TestAsset new]; }
static NSURL *tgextraExtractAudio(AVAsset *asset, CMTimeRange range, NSString *baseName) {
    exportedRange = range;
    return [NSURL fileURLWithPath:@"/tmp/trimmed-voice.m4a"];
}
'''
tests = r'''
static void checkTrim(NSDictionary *description, id context, double start, double end) {
    NSDictionary *result = tgextraRewriteToVoice(description, context);
    NSCAssert([result[@"type"] isEqual:@"file"] && result[@"tempFileUrl"], @"Produce a voice upload source");
    NSCAssert(CMTimeGetSeconds(exportedRange.start) == start &&
        CMTimeGetSeconds(CMTimeRangeGetEnd(exportedRange)) == end, @"Export exactly the selected audio range");
}
int main(void) { @autoreleasepool {
    TestAdjustments *adjustments = [TestAdjustments new];
    adjustments.trimApplied = YES;
    adjustments.trimStartValue = 2;
    adjustments.trimEndValue = 5;
    TestContext *context = [TestContext new];
    context.adjustments = adjustments;
    for (id url in @[@"/tmp/camera.mp4", [NSURL fileURLWithPath:@"/tmp/camera.mp4"]]) {
        checkTrim(@{@"type": @"cameraVideo", @"url": url, @"adjustments": adjustments}, context, 2, 5);
        checkTrim(@{@"type": @"cameraVideo", @"url": url}, nil, 0, 10);
    }
    NSDictionary *photo = @{@"type": @"video", @"asset": [NSObject new]};
    checkTrim(photo, context, 2, 5);
    TestAdjustments *current = [TestAdjustments new];
    current.trimApplied = YES;
    current.trimStartValue = 3;
    current.trimEndValue = 6;
    checkTrim(@{@"type": @"video", @"asset": photo[@"asset"], @"adjustments": current}, context, 3, 6);
    for (NSArray *range in @[@[@0, @4], @[@2, @5.5]]) {
        adjustments.trimStartValue = [range[0] doubleValue];
        adjustments.trimEndValue = [range[1] doubleValue];
        checkTrim(@{@"type": @"cameraVideo", @"adjustments": adjustments}, nil,
            adjustments.trimStartValue, adjustments.trimEndValue);
    }
    adjustments.trimApplied = NO;
    checkTrim(@{@"type": @"cameraVideo", @"adjustments": adjustments}, nil, 0, 10);
    adjustments.trimApplied = YES;
    for (NSArray *range in @[@[@5, @2], @[@2, @2], @[@-1, @5], @[@(NAN), @5], @[@2, @(INFINITY)]]) {
        adjustments.trimStartValue = [range[0] doubleValue];
        adjustments.trimEndValue = [range[1] doubleValue];
        checkTrim(@{@"type": @"cameraVideo", @"adjustments": adjustments}, nil, 0, 10);
    }
    checkTrim(@{@"type": @"cameraVideo", @"adjustments": [NSObject new]}, nil, 0, 10);
    puts("PASS voice export trim: camera descriptions, Photos fallback, current edits, fractional ranges and invalid adjustments");
} return 0; }
'''
with tempfile.TemporaryDirectory(prefix='tgextra-voice-trim-') as directory:
    work = Path(directory)
    harness = work / 'tests.m'
    harness.write_text(support + trim + rewrite + tests)
    binary = work / 'tests'
    subprocess.run(['clang', '-fobjc-arc', '-Werror', '-Wno-deprecated-declarations',
                    '-framework', 'Foundation', '-framework', 'AVFoundation', '-framework', 'CoreMedia',
                    str(harness), '-o', str(binary)], check=True)
    subprocess.run([str(binary)], check=True)
