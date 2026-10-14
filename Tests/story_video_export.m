#import <AVFoundation/AVFoundation.h>
#import "../Sources/tgapi/StoryVideoExport.h"
#import <math.h>

static void check(BOOL condition, NSString *message) {
    if (!condition) {
        NSLog(@"FAIL %@", message);
        exit(1);
    }
}

static NSURL *rotateFixture(NSURL *inputURL, NSString *directory) {
    AVURLAsset *source = [AVURLAsset URLAssetWithURL:inputURL options:nil];
    AVMutableComposition *asset = [AVMutableComposition composition];
    AVMutableCompositionTrack *track = [asset addMutableTrackWithMediaType:AVMediaTypeVideo
                                                        preferredTrackID:kCMPersistentTrackID_Invalid];
    NSError *error = nil;
    check([track insertTimeRange:CMTimeRangeMake(kCMTimeZero, source.duration)
                        ofTrack:[source tracksWithMediaType:AVMediaTypeVideo].firstObject
                         atTime:kCMTimeZero error:&error], @"Create rotated fixture");
    track.preferredTransform = CGAffineTransformMake(0, 1, -1, 0, 64, 0);
    NSURL *url = [NSURL fileURLWithPath:[directory stringByAppendingPathComponent:@"rotated.mov"]];
    AVAssetExportSession *export = [[AVAssetExportSession alloc]
        initWithAsset:asset presetName:AVAssetExportPresetPassthrough];
    export.outputURL = url;
    export.outputFileType = AVFileTypeQuickTimeMovie;
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    [export exportAsynchronouslyWithCompletionHandler:^{ dispatch_semaphore_signal(done); }];
    check(dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, 30 * NSEC_PER_SEC)) == 0,
          @"Rotated fixture export completes");
    check(export.status == AVAssetExportSessionStatusCompleted, @"Rotated fixture exported");
    return url;
}

static void verifyExport(NSURL *sourceURL, BOOL hasAudio, CGSize expectedSize) {
    NSData *original = [NSData dataWithContentsOfURL:sourceURL];
    AVURLAsset *source = [AVURLAsset URLAssetWithURL:sourceURL options:nil];
    NSURL *url = TGExtraExportStoryVideo(sourceURL);
    check(url != nil && ![url isEqual:sourceURL], @"Export returns a separate file");
    AVURLAsset *output = [AVURLAsset URLAssetWithURL:url options:nil];
    AVAssetTrack *video = [output tracksWithMediaType:AVMediaTypeVideo].firstObject;
    check(video != nil, @"Export retains video");
    check(fabs(video.nominalFrameRate - 30) < 0.01, @"Export uses 30 fps");
    check(fabs(CMTimeGetSeconds(output.duration) - CMTimeGetSeconds(source.duration)) < 0.08,
          @"Export preserves playback duration");
    check(([output tracksWithMediaType:AVMediaTypeAudio].count > 0) == hasAudio,
          @"Export preserves audio presence");
    if (hasAudio) {
        AVAssetTrack *audio = [output tracksWithMediaType:AVMediaTypeAudio].firstObject;
        check(fabs(CMTimeGetSeconds(audio.timeRange.duration) - CMTimeGetSeconds(source.duration)) < 0.08,
              @"Export keeps audio synchronized");
        CMAudioFormatDescriptionRef audioFormat = (__bridge CMAudioFormatDescriptionRef)audio.formatDescriptions.firstObject;
        check(CMFormatDescriptionGetMediaSubType(audioFormat) == kAudioFormatMPEG4AAC, @"AAC audio");
    }
    CMVideoFormatDescriptionRef format = (__bridge CMVideoFormatDescriptionRef)video.formatDescriptions.firstObject;
    check(CMFormatDescriptionGetMediaSubType(format) == kCMVideoCodecType_H264, @"H.264 video");
    CGRect bounds = CGRectApplyAffineTransform((CGRect){CGPointZero, video.naturalSize}, video.preferredTransform);
    check(fabs(bounds.size.width - expectedSize.width) < 1 &&
          fabs(bounds.size.height - expectedSize.height) < 1, @"Preserve display dimensions and rotation");

    // Count decoded frames, rather than trusting nominalFrameRate metadata.
    NSError *error = nil;
    AVAssetReader *reader = [[AVAssetReader alloc] initWithAsset:output error:&error];
    AVAssetReaderTrackOutput *frames = [[AVAssetReaderTrackOutput alloc] initWithTrack:video
        outputSettings:@{(id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA)}];
    [reader addOutput:frames];
    check([reader startReading], @"Read exported frames");
    NSInteger count = 0;
    CMSampleBufferRef sample;
    while ((sample = [frames copyNextSampleBuffer])) {
        count++;
        CFRelease(sample);
    }
    check(reader.status == AVAssetReaderStatusCompleted, @"All output frames decode");
    check(labs(count - lround(CMTimeGetSeconds(source.duration) * 30)) <= 1,
          @"Frame count matches original duration at 30 fps");
    check([[NSData dataWithContentsOfURL:sourceURL] isEqual:original], @"Source file stays untouched");
    [[NSFileManager defaultManager] removeItemAtURL:url error:NULL];
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        check(argc == 2 || argc == 3, @"Fixture directory supplied, with an optional real video");
        NSString *directory = [NSString stringWithUTF8String:argv[1]];
        NSURL *highFPS = [NSURL fileURLWithPath:[directory stringByAppendingPathComponent:@"high-fps.mp4"]];
        check(TGExtraExportStoryVideo(highFPS) == nil, @"Never block the main thread");
        dispatch_semaphore_t done = dispatch_semaphore_create(0);
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            @autoreleasepool {
                check(TGExtraStoryVideoNeedsNormalization(highFPS), @"120 fps input needs normalization");
                verifyExport(highFPS, YES, CGSizeMake(96, 64));
                verifyExport(highFPS, YES, CGSizeMake(96, 64));
                NSURL *silent = [NSURL fileURLWithPath:[directory stringByAppendingPathComponent:@"silent.mp4"]];
                check(!TGExtraStoryVideoNeedsNormalization(silent), @"Ordinary video needs no normalization");
                verifyExport(silent, NO, CGSizeMake(96, 64));
                verifyExport(rotateFixture(silent, directory), NO, CGSizeMake(64, 96));
                NSURL *broken = [NSURL fileURLWithPath:[directory stringByAppendingPathComponent:@"broken.mp4"]];
                [@"invalid video" writeToURL:broken atomically:YES encoding:NSUTF8StringEncoding error:NULL];
                check(TGExtraExportStoryVideo(broken) == nil, @"Reject corrupt input");
                check(TGExtraExportStoryVideo([NSURL URLWithString:@"https://example.com/video.mp4"]) == nil,
                      @"Reject nonlocal input");
                if (argc == 3) {
                    NSURL *realURL = [NSURL fileURLWithPath:[NSString stringWithUTF8String:argv[2]]];
                    AVURLAsset *real = [AVURLAsset URLAssetWithURL:realURL options:nil];
                    AVAssetTrack *video = [real tracksWithMediaType:AVMediaTypeVideo].firstObject;
                    CGRect bounds = CGRectApplyAffineTransform((CGRect){CGPointZero, video.naturalSize}, video.preferredTransform);
                    verifyExport(realURL, [real tracksWithMediaType:AVMediaTypeAudio].count > 0, bounds.size);
                    NSLog(@"PASS real video duration=%.3f and audio", CMTimeGetSeconds(real.duration));
                }
                NSLog(@"PASS story video rate, duration, audio, rotation, repeated saves and invalid input");
                dispatch_semaphore_signal(done);
            }
        });
        check(dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, 120 * NSEC_PER_SEC)) == 0,
              @"Video tests finish within timeout");
    }
    return 0;
}
