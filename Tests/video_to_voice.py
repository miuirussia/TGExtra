#!/usr/bin/env python3
"""Exercise the production preview toggle and send wrapper without UIKit."""
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parent.parent
source = (ROOT / 'Sources/tgapi/VideoToVoice.xm').read_text()
selection = (ROOT / 'Sources/tgapi/VoiceSelection.m').read_text()
helpers = selection[selection.index('BOOL tgextraVideoToVoiceEnabled('):]
preview = (ROOT / 'Sources/tgapi/VideoConversionPreview.xm').read_text()
toggle = preview[preview.index('@interface TGExtraVoiceToggleTarget'):preview.index('static UIView *tgextraFindSubviewByClassSubstring')]
send = source[source.index('+ (NSArray *)resultSignalsForSelectionContext:'):source.index('%end')]
send = send.replace('return %orig;', 'return testOriginal(descriptionGenerator);')
send = send.replace('return %orig(selectionContext, editingContext, intent, currentItem, storeAssets,\n                 convertToJpeg, wrapped, saveEditedPhotos);', 'return testOriginal(wrapped);')
send = send.replace('%orig(selectionContext, editingContext, intent, currentItem, storeAssets,\n                            convertToJpeg, wrapped, saveEditedPhotos)', 'testOriginal(wrapped)')
conversion_helpers = source[source.index('@interface NSObject (TGExtraVideoConversionSignals)'):source.index('%group')] if '@interface NSObject (TGExtraVideoConversionSignals)' in source else ''

support = r'''
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import "Constants.h"
typedef id (^TGExtraDescriptionGenerator)(id, NSAttributedString *, NSString *, NSString *);
static const void *kTGExtraVoicePreviewItemKey = &kTGExtraVoicePreviewItemKey;
static TGExtraDescriptionGenerator generator;
static TGExtraDescriptionGenerator rawGenerator;
static id testValue;
static BOOL roundSupported = YES;
static BOOL descriptionFails;
static __weak id conversionResource;
extern id testAutoreleasedConversionResource(void);
@interface TLParser : NSObject
+ (BOOL)roundVideoChatSupported;
@end
@implementation TLParser
+ (BOOL)roundVideoChatSupported { return roundSupported; }
@end
@interface SQueue : NSObject
@property dispatch_queue_t queue;
- (void)dispatch:(dispatch_block_t)block;
@end
@implementation SQueue
- (instancetype)init {
    if ((self = [super init])) _queue = dispatch_queue_create("test.conversion", DISPATCH_QUEUE_SERIAL);
    return self;
}
- (void)dispatch:(dispatch_block_t)block { dispatch_async(_queue, block); }
@end
@interface SSignal : NSObject
@property (copy) void (^subscribe)(void (^)(id), dispatch_block_t);
- (id)deliverOn:(SQueue *)queue;
- (id)map:(id (^)(id))transform;
@end
@implementation SSignal
- (id)deliverOn:(SQueue *)queue {
    SSignal *result = [SSignal new];
    result.subscribe = ^(void (^next)(id), dispatch_block_t complete) {
        self.subscribe(^(id value) { [queue dispatch:^{ next(value); }]; },
                       ^{ [queue dispatch:complete]; });
    };
    return result;
}
- (id)map:(id (^)(id))transform {
    SSignal *result = [SSignal new];
    result.subscribe = ^(void (^next)(id), dispatch_block_t complete) {
        self.subscribe(^(id value) {
            id result = transform(value);
            NSCAssert(conversionResource == nil, @"Release temporary conversion resources before delivering the result");
            next(result);
        }, complete);
    };
    return result;
}
@end
static NSUInteger conversions;
static BOOL conversionFails;
static BOOL conversionThrows;
static NSArray *testOriginal(TGExtraDescriptionGenerator block) {
    rawGenerator = [block copy];
    SSignal *signal = [SSignal new];
    signal.subscribe = ^(void (^next)(id), dispatch_block_t complete) { next(testValue); complete(); };
    return @[signal];
}
static NSDictionary *tgextraRewriteToVoice(id dict, id context) {
    NSCAssert(!NSThread.isMainThread, @"Audio extraction must not block the UI thread");
    if (![dict isKindOfClass:NSDictionary.class] || ![@[@"video", @"cameraVideo"] containsObject:dict[@"type"]]) return nil;
    if (conversionThrows) [NSException raise:@"Extraction" format:@"Failed"];
    if (conversionFails) return nil;
    conversions++;
    return @{@"type": @"voice"};
}
static NSDictionary *tgextraRewriteToRound(id dict, id context) {
    NSCAssert(!NSThread.isMainThread, @"Round export rejects the UI thread");
    conversionResource = testAutoreleasedConversionResource();
    // Main-thread work must keep running while the export waits for completion.
    dispatch_semaphore_t ui = dispatch_semaphore_create(0);
    dispatch_async(dispatch_get_main_queue(), ^{ dispatch_semaphore_signal(ui); });
    NSCAssert(dispatch_semaphore_wait(ui, dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC)) == 0,
              @"Round export must leave the UI responsive");
    if (conversionThrows) [NSException raise:@"Conversion" format:@"Failed"];
    if (conversionFails) return nil;
    return @{@"type": @"round"};
}
#define tgextraDiag(...) ((void)0)
static void customLog(NSString *format, ...) {}
static void TGExtraShowToast(NSString *text) {}
@interface TGExtraLocalization : NSObject
+ (NSString *)localizedStringForKey:(NSString *)key;
@end
@implementation TGExtraLocalization
+ (NSString *)localizedStringForKey:(NSString *)key { return key; }
@end
@interface UIButton : NSObject
@property NSString *accessibilityValue;
@property BOOL active;
@property UIButton *superview;
- (void)setNeedsLayout;
@end
@implementation UIButton
- (void)setNeedsLayout {}
@end
static void tgextraStyleVoiceButton(UIButton *button, BOOL enabled) { button.active = enabled; }
static void tgextraStyleRoundButton(UIButton *button, BOOL enabled) { button.active = enabled; }
#define UIImpactFeedbackStyleMedium 1
@interface UIImpactFeedbackGenerator : NSObject
- (instancetype)initWithStyle:(NSInteger)style;
- (void)impactOccurred;
@end
@implementation UIImpactFeedbackGenerator
- (instancetype)initWithStyle:(NSInteger)style { return [super init]; }
- (void)impactOccurred {}
@end
@interface TestAsset : NSObject
@property NSString *uniqueIdentifier;
@end
@implementation TestAsset
@end
@interface TestGalleryItem : NSObject
@property id editingContext;
@property id editableMediaItem;
@end
@implementation TestGalleryItem
@end
'''

tests = r'''
@end
static void prepareSend(id context) {
    NSArray *signals = [TestSender resultSignalsForSelectionContext:nil editingContext:context intent:0
        currentItem:nil storeAssets:NO convertToJpeg:NO descriptionGenerator:
        ^id(id dict, NSAttributedString *caption, NSString *hash, NSString *uniqueId) {
            NSCAssert((!caption && !hash) || ([caption.string isEqual:@"caption"] && [hash isEqual:@"hash"]), @"Preserve caption and hash");
            return descriptionFails ? nil : dict;
        } saveEditedPhotos:NO];
    TGExtraDescriptionGenerator produce = rawGenerator;
    generator = ^id(id dict, NSAttributedString *caption, NSString *hash, NSString *uniqueId) {
        NSCAssert(NSThread.isMainThread, @"Reproduce synchronous picker delivery on the UI thread");
        testValue = produce(dict, caption, hash, uniqueId);
        __block id result;
        __block BOOL finished = NO;
        __block BOOL received = NO;
        ((SSignal *)signals[0]).subscribe(^(id value) {
            // SSignal.combineSignals never emits a batch containing nil. The
            // picker enqueue bridge only finishes after it receives that batch.
            if (!value) return;
            dispatch_async(dispatch_get_main_queue(), ^{ result = value; received = YES; });
        }, ^{ dispatch_async(dispatch_get_main_queue(), ^{ finished = YES; }); });
        NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:5];
        while (!finished && deadline.timeIntervalSinceNow > 0) {
            [NSRunLoop.currentRunLoop runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
        }
        NSCAssert(finished, @"Conversion signal completes after its converted value");
        NSCAssert(received, @"Telegram's enqueue bridge must receive a value even when conversion fails");
        return result;
    };
}
static id sendItem(NSString *type, id asset, NSString *uniqueId) {
    NSDictionary *dict = @{@"type": type, @"asset": asset};
    return generator(dict, [[NSAttributedString alloc] initWithString:@"caption"], @"hash", uniqueId);
}
int main(void) {
    @autoreleasepool {
        NSString *suite = [@"TGExtraVoiceTest-" stringByAppendingString:NSUUID.UUID.UUIDString];
        NSUserDefaults *defaults = [[NSUserDefaults alloc] initWithSuiteName:suite];
        Method method = class_getClassMethod(NSUserDefaults.class, @selector(standardUserDefaults));
        method_setImplementation(method, imp_implementationWithBlock(^id(id cls) { return defaults; }));
        NSCAssert(!tgextraVideoToVoiceEnabled(), @"Feature defaults off");
        [defaults setBool:YES forKey:kVideoToVoice];
        NSObject *context = [NSObject new];
        TestAsset *asset = [TestAsset new]; asset.uniqueIdentifier = @"video-1";
        TestGalleryItem *item = [TestGalleryItem new];
        item.editingContext = context; item.editableMediaItem = asset;
        UIButton *button = [UIButton new];
        objc_setAssociatedObject(button, kTGExtraVoicePreviewItemKey, item, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        NSCAssert(tgextraVoiceItems(context).count == 0, @"A new picker starts with conversion off");
        prepareSend(context);
        NSCAssert([sendItem(@"video", asset, @"video-1")[@"type"] isEqual:@"video"], @"The feature setting alone never converts videos");
        [[TGExtraVoiceToggleTarget shared] handleTap:button];
        NSCAssert(button.active && [button.accessibilityValue isEqual:@"VIDEO_TO_VOICE_ON_TOAST"], @"Tap enables the current clip and updates accessibility");
        NSCAssert([defaults boolForKey:kVideoToVoice], @"Enabling a clip preserves the setting");
        prepareSend(context);
        NSCAssert([sendItem(@"video", asset, @"video-1")[@"type"] isEqual:@"voice"], @"Convert the selected video");
        NSCAssert([sendItem(@"video", asset, @"video-2")[@"type"] isEqual:@"video"], @"Other videos in the same batch stay videos");
        NSCAssert([sendItem(@"photo", asset, @"video-1")[@"type"] isEqual:@"photo"], @"Leave photos unchanged");
        TestAsset *sameAsset = [TestAsset new]; sameAsset.uniqueIdentifier = @"video-1";
        NSCAssert([sendItem(@"video", sameAsset, nil)[@"type"] isEqual:@"voice"], @"Match replacement asset objects by identifier");
        [[TGExtraVoiceToggleTarget shared] handleTap:button];
        NSCAssert(!button.active && [button.accessibilityValue isEqual:@"VIDEO_TO_VOICE_OFF_TOAST"], @"Tap disables the clip");
        NSCAssert([defaults boolForKey:kVideoToVoice], @"Disabling a clip must not clear the settings checkbox");
        NSCAssert([sendItem(@"video", asset, @"video-1")[@"type"] isEqual:@"voice"], @"An in-flight send keeps its selection snapshot");
        prepareSend(context);
        NSCAssert([sendItem(@"video", asset, @"video-1")[@"type"] isEqual:@"video"], @"The next send respects the disabled clip");
        tgextraToggleVoiceItem(item);
        NSCAssert(tgextraVoiceItems([NSObject new]).count == 0, @"Another picker never inherits conversion choices");
        NSCAssert(!tgextraToggleVoiceItem([NSObject new]) && tgextraVoiceItems(nil).count == 0, @"Unsupported host objects stay off");
        [defaults setBool:NO forKey:kVideoToVoice];
        [[TGExtraVoiceToggleTarget shared] handleTap:button];
        prepareSend(context);
        NSCAssert([sendItem(@"video", asset, @"video-1")[@"type"] isEqual:@"video"], @"Disabling the feature bypasses conversion");
        [defaults setBool:YES forKey:kVideoToVoice];
        NSURL *url = [NSURL fileURLWithPath:@"/tmp/captured-video.mp4"];
        TestAsset *camera = [TestAsset new]; camera.uniqueIdentifier = url.absoluteString;
        item.editableMediaItem = camera;
        tgextraToggleVoiceItem(item);
        prepareSend(context);
        id result = generator(@{@"type": @"cameraVideo", @"url": url},
            [[NSAttributedString alloc] initWithString:@"caption"], @"hash", nil);
        NSCAssert([result[@"type"] isEqual:@"voice"], @"Camera videos match their file URL when the send has no identifier");
        result = generator(@{@"type": @"cameraVideo", @"url": url.path},
            [[NSAttributedString alloc] initWithString:@"caption"], @"hash", nil);
        NSCAssert([result[@"type"] isEqual:@"voice"], @"Also accept camera paths passed as strings");
        NSCAssert(conversions == 5, @"Only explicitly selected videos reach extraction");
        conversionFails = YES;
        NSCAssert([generator(@{@"type": @"cameraVideo", @"url": url}, nil, nil, nil) count] == 0,
                  @"Failed conversion emits an empty description, completing the send without the source video");
        conversionThrows = YES;
        NSCAssert([generator(@{@"type": @"cameraVideo", @"url": url}, nil, nil, nil) count] == 0,
                  @"An extraction exception completes the send without the source video");
        conversionFails = NO; conversionThrows = NO;
        NSCAssert(!tgextraVideoToRoundEnabled(), @"Round conversion defaults off");
        [defaults setBool:YES forKey:kVideoToRound];
        [[TGExtraVoiceToggleTarget shared] handleRoundTap:button];
        NSCAssert(button.active && [button.accessibilityValue isEqual:@"VIDEO_TO_ROUND_ON_TOAST"], @"Enable round conversion");
        NSCAssert(![tgextraVoiceItems(context) containsObject:url.absoluteString], @"Round selection clears voice selection");
        prepareSend(context);
        NSCAssert([generator(@{@"type": @"cameraVideo", @"url": url}, nil, nil, nil)[@"type"] isEqual:@"round"], @"Convert camera video to round");
        NSCAssert([sendItem(@"photo", camera, url.absoluteString)[@"type"] isEqual:@"photo"], @"Round selection leaves photos unchanged");
        [[TGExtraVoiceToggleTarget shared] handleTap:button];
        NSCAssert(![tgextraRoundItems(context) containsObject:url.absoluteString], @"Voice selection clears round selection");
        NSCAssert([generator(@{@"type": @"cameraVideo", @"url": url}, nil, nil, nil)[@"type"] isEqual:@"round"], @"Round send keeps its selection snapshot");
        [[TGExtraVoiceToggleTarget shared] handleRoundTap:button];
        [[TGExtraVoiceToggleTarget shared] handleRoundTap:button];
        NSCAssert(tgextraRoundItems(context).count == 0, @"Second tap disables round mode");
        tgextraToggleRoundItem(item);
        [defaults setBool:NO forKey:kVideoToVoice];
        prepareSend(context);
        NSCAssert([generator(@{@"type": @"cameraVideo", @"url": url}, nil, nil, nil)[@"type"] isEqual:@"round"], @"Round conversion works with voice feature off");
        NSCAssert(tgextraRoundItems([NSObject new]).count == 0, @"Round selections stay in their picker");
        conversionFails = YES;
        NSCAssert([generator(@{@"type": @"cameraVideo", @"url": url}, nil, nil, nil) count] == 0,
                  @"Round failure completes the send without the original video");
        conversionThrows = YES;
        NSCAssert([generator(@{@"type": @"cameraVideo", @"url": url}, nil, nil, nil) count] == 0,
                  @"Round exception completes the send without the original video");
        conversionFails = NO; conversionThrows = NO;
        NSCAssert([generator(@{@"type": @"cameraVideo", @"url": url}, nil, nil, nil)[@"type"] isEqual:@"round"],
                  @"A round conversion succeeds after a failure without restarting the picker");
        descriptionFails = YES;
        NSCAssert([generator(@{@"type": @"cameraVideo", @"url": url}, nil, nil, nil) count] == 0,
                  @"A rejected host description also completes the send without media");
        descriptionFails = NO;
        [defaults setBool:NO forKey:kVideoToRound];
        prepareSend(context);
        NSCAssert([generator(@{@"type": @"cameraVideo", @"url": url}, nil, nil, nil)[@"type"] isEqual:@"cameraVideo"], @"Disabled round feature bypasses conversion");
        [defaults removePersistentDomainForName:suite];
        puts("PASS video conversion: UI-thread picker delivery, background export, responsive UI, signal completion, per-clip selection, snapshots and failures");
    }
    return 0;
}
'''

with tempfile.TemporaryDirectory(prefix='tgextra-video-voice-') as tmp:
    path = Path(tmp)
    harness = path / 'voice.m'
    sender = '@interface TestSender : NSObject\n' + send[:send.index(' {')] + ';\n@end\n@implementation TestSender\n'
    harness.write_text(support + helpers + toggle + conversion_helpers + sender + send + tests)
    resource = path / 'resource.m'
    resource.write_text('#import <Foundation/Foundation.h>\nid testAutoreleasedConversionResource(void) { return [[[NSObject alloc] init] autorelease]; }\n')
    resource_object = path / 'resource.o'
    subprocess.run(['clang', '-fno-objc-arc', '-c', str(resource), '-o', str(resource_object)], check=True)
    binary = path / 'voice'
    subprocess.run(['clang', '-fobjc-arc', '-Werror', '-framework', 'Foundation',
                    '-I' + str(ROOT / 'Sources/tgapi'), str(harness), str(resource_object), '-o', str(binary)], check=True)
    subprocess.run([str(binary)], check=True)
