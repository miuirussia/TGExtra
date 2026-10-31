// Include the implementation to exercise its private waits with short deadlines.
#import "../Sources/tgapi/RoundVideoExport.m"

static void check(BOOL condition, NSString *message) {
    if (!condition) { NSLog(@"FAIL %@", message); exit(1); }
}

@interface TestRoundExport : NSObject
@property BOOL advances;
@property float value;
@end
@implementation TestRoundExport
- (float)progress { if (self.advances) self.value += 0.01; return self.value; }
- (AVAssetExportSessionStatus)status { return AVAssetExportSessionStatusExporting; }
@end

@interface TestRoundPreview : NSObject
@property (copy) AVAssetImageGeneratorCompletionHandler handler;
@property BOOL succeeds;
@property BOOL cancelled;
- (void)finish;
@end
@implementation TestRoundPreview
- (void)generateCGImagesAsynchronouslyForTimes:(NSArray *)times
                           completionHandler:(AVAssetImageGeneratorCompletionHandler)handler {
    self.handler = handler;
    if (self.succeeds) [self finish];
}
- (void)finish {
    CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
    CGContextRef context = CGBitmapContextCreate(NULL, 4, 4, 8, 16, space,
                                                (CGBitmapInfo)kCGImageAlphaPremultipliedLast);
    CGImageRef image = CGBitmapContextCreateImage(context);
    self.handler(kCMTimeZero, image, kCMTimeZero, AVAssetImageGeneratorSucceeded, nil);
    CGImageRelease(image);
    CGContextRelease(context);
    CGColorSpaceRelease(space);
    self.handler = nil;
}
- (void)cancelAllCGImageGeneration { self.cancelled = YES; }
@end

int main(void) { @autoreleasepool {
    TestRoundExport *export = [TestRoundExport new];
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    NSTimeInterval started = NSProcessInfo.processInfo.systemUptime;
    check(!tgextraWaitForRoundExport((id)export, done, 1, 0.03), @"A stalled export times out");
    check(NSProcessInfo.processInfo.systemUptime - started < 0.5, @"Do not wait for the full export deadline after a stall");

    // Progress extends the stall deadline, but cannot extend the total deadline.
    export.advances = YES;
    check(!tgextraWaitForRoundExport((id)export, done, 0.1, 0.03), @"Enforce the total deadline even with progress");
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC / 10),
        dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{ dispatch_semaphore_signal(done); });
    check(tgextraWaitForRoundExport((id)export, done, 1, 0.03), @"Progressing exports finish after a previous timeout");

    TestRoundPreview *generator = [TestRoundPreview new];
    check(tgextraCopyRoundPreview((id)generator, 0.01) == NULL && generator.cancelled,
          @"A hung preview is cancelled and cannot block the send");
    // A callback can race with cancellation; it must not retain an abandoned image.
    [generator finish];
    generator.succeeds = YES;
    CGImageRef image = tgextraCopyRoundPreview((id)generator, 0.1);
    check(image != NULL && CGImageGetWidth(image) == 4, @"The next preview succeeds after a timeout and late callback");
    CGImageRelease(image);
    check(TGExtraCopyRoundVideoPreview([AVMutableComposition composition]) == NULL,
          @"Preview generation never blocks the main thread");
    puts("PASS round video recovery: stalled export, total deadline, progress, preview cancellation, late callbacks and retry");
} return 0; }
