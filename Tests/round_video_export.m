#import "../Sources/tgapi/RoundVideoExport.h"

static void check(BOOL valid, NSString *message) {
    if (!valid) { NSLog(@"FAIL %@", message); exit(1); }
}

static void checkGreen(AVAsset *asset) {
    AVAssetImageGenerator *generator = [AVAssetImageGenerator assetImageGeneratorWithAsset:asset];
    generator.appliesPreferredTrackTransform = YES;
    CGImageRef image = [generator copyCGImageAtTime:kCMTimeZero actualTime:NULL error:NULL];
    check(image != NULL, @"Decode exported thumbnail");
    size_t width = CGImageGetWidth(image), height = CGImageGetHeight(image);
    NSMutableData *data = [NSMutableData dataWithLength:width * height * 4];
    unsigned char *pixels = data.mutableBytes;
    CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
    CGContextRef context = CGBitmapContextCreate(pixels, width, height, 8, width * 4, space,
                                               (CGBitmapInfo)kCGImageAlphaPremultipliedLast);
    CGContextDrawImage(context, CGRectMake(0, 0, width, height), image);
    for (int y = 1; y <= 3; y++) for (int x = 1; x <= 3; x++) {
        size_t i = ((height * y / 4) * width + width * x / 4) * 4;
        check(pixels[i + 1] > 150 && pixels[i + 1] > pixels[i] * 1.5 &&
              pixels[i + 1] > pixels[i + 2] * 1.5,
              @"Selected trim is green across the centered square, without colored sidebars");
    }
    CGContextRelease(context); CGColorSpaceRelease(space); CGImageRelease(image);
}

static void verify(AVAsset *source, CMTimeRange range, double duration, BOOL audio, BOOL green) {
    NSURL *url = TGExtraExportRoundVideo(source, range);
    check(url != nil, @"Round export succeeds");
    AVURLAsset *asset = [AVURLAsset URLAssetWithURL:url options:nil];
    AVAssetTrack *video = [asset tracksWithMediaType:AVMediaTypeVideo].firstObject;
    check(video.naturalSize.width == 384 && video.naturalSize.height == 384, @"384x384 square output");
    check(fabs(CMTimeGetSeconds(asset.duration) - duration) < 0.1, @"Respect trim and 60-second limit");
    check(fabs(video.nominalFrameRate - 30) < 0.1, @"30 fps output");
    CMFormatDescriptionRef format = (__bridge CMFormatDescriptionRef)video.formatDescriptions.firstObject;
    check(CMFormatDescriptionGetMediaSubType(format) == kCMVideoCodecType_H264, @"H.264 output");
    NSArray *tracks = [asset tracksWithMediaType:AVMediaTypeAudio];
    check((tracks.count != 0) == audio, @"Preserve audio when present and allow silent video");
    if (audio) {
        format = (__bridge CMFormatDescriptionRef)[tracks.firstObject formatDescriptions].firstObject;
        check(CMFormatDescriptionGetMediaSubType(format) == kAudioFormatMPEG4AAC, @"AAC audio");
    }
    if (green) checkGreen(asset);
    [NSFileManager.defaultManager removeItemAtURL:url error:NULL];
}

int main(int argc, const char **argv) { @autoreleasepool {
    check(argc == 2, @"Supply fixtures");
    NSString *directory = @(argv[1]);
    AVURLAsset *source = [AVURLAsset URLAssetWithURL:[NSURL fileURLWithPath:
        [directory stringByAppendingPathComponent:@"source.mp4"]] options:nil];
    AVURLAsset *silent = [AVURLAsset URLAssetWithURL:[NSURL fileURLWithPath:
        [directory stringByAppendingPathComponent:@"silent.mp4"]] options:nil];
    NSData *original = [NSData dataWithContentsOfURL:source.URL];
    CMTimeRange trim = CMTimeRangeMake(CMTimeMake(1, 1), CMTimeMake(1, 1));
    check(TGExtraExportRoundVideo(source, trim) == nil, @"Never block main thread");
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{ @autoreleasepool {
        verify(source, trim, 1, YES, YES);
        verify(silent, trim, 1, NO, YES);
        for (NSValue *value in @[
            [NSValue valueWithBytes:&(CGAffineTransform){0, 1, -1, 0, 64, 0} objCType:@encode(CGAffineTransform)],
            [NSValue valueWithBytes:&(CGAffineTransform){-1, 0, 0, -1, 128, 64} objCType:@encode(CGAffineTransform)],
            [NSValue valueWithBytes:&(CGAffineTransform){-1, 0, 0, 1, 128, 0} objCType:@encode(CGAffineTransform)]]) {
            AVMutableComposition *rotated = [AVMutableComposition composition];
            AVMutableCompositionTrack *track = [rotated addMutableTrackWithMediaType:AVMediaTypeVideo
                preferredTrackID:kCMPersistentTrackID_Invalid];
            check([track insertTimeRange:CMTimeRangeMake(kCMTimeZero, silent.duration)
                ofTrack:[silent tracksWithMediaType:AVMediaTypeVideo].firstObject atTime:kCMTimeZero error:NULL], @"Prepare orientation fixture");
            CGAffineTransform transform; [value getValue:&transform size:sizeof(transform)];
            track.preferredTransform = transform;
            verify(rotated, trim, 1, NO, YES);
        }
        AVMutableComposition *longClip = [AVMutableComposition composition];
        AVMutableCompositionTrack *track = [longClip addMutableTrackWithMediaType:AVMediaTypeVideo
            preferredTrackID:kCMPersistentTrackID_Invalid];
        for (int i = 0; i < 21; i++) {
            check([track insertTimeRange:CMTimeRangeMake(kCMTimeZero, silent.duration)
                ofTrack:[silent tracksWithMediaType:AVMediaTypeVideo].firstObject
                atTime:longClip.duration error:NULL], @"Prepare long fixture");
        }
        verify(longClip, CMTimeRangeMake(kCMTimeZero, longClip.duration), 60, NO, NO);
        check(TGExtraExportRoundVideo(source, CMTimeRangeMake(CMTimeMake(10, 1), CMTimeMake(1, 1))) == nil,
              @"Reject out-of-bounds trim");
        check(TGExtraExportRoundVideo(source, CMTimeRangeMake(kCMTimeZero, kCMTimeZero)) == nil,
              @"Reject empty trim");
        check(TGExtraExportRoundVideo([AVMutableComposition composition], trim) == nil, @"Reject missing video track");
        check([[NSData dataWithContentsOfURL:source.URL] isEqual:original], @"Preserve source file");
        dispatch_semaphore_signal(done);
    } });
    check(dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, 120 * NSEC_PER_SEC)) == 0, @"Tests complete");
    puts("PASS round video export: crop pixels, trim, 60s limit, 384x384 H.264/AAC, rotation, mirroring, silent video and invalid input");
} return 0; }
