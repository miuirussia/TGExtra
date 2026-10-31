#!/usr/bin/env python3
"""Exercise production capture policy with UIKit/CoreAnimation stand-ins."""
from pathlib import Path
import re
import subprocess
import tempfile

root = Path(__file__).resolve().parent.parent
source = (root / 'Sources/tgapi/MediaCapture.xm').read_text()
helpers = source[source.index('static char paidCaptureRootKey'):source.index('%group TGExtraGalleryCaptureViews')]
view_hook = source[source.index('%hook TGExtraGalleryCaptureView'):source.index('%end', source.index('%hook TGExtraGalleryCaptureView'))]
view_hook = (view_hook.replace('%hook TGExtraGalleryCaptureView', '@implementation TestGalleryView')
             .replace('%orig;', '[super layoutSubviews];', 1)
             .replace('%orig;', '[super didMoveToWindow];', 1) + '@end\n')
hooks = source[source.index('%hook UIView'):source.index('__attribute__((constructor))')]
for host, replacement in [('UIView', 'TestTextLayoutCanvasView'), ('UITextField', 'TestTextField'),
                          ('AVSampleBufferDisplayLayer', 'TestVideoLayer'), ('CALayer', 'TestLayer')]:
    hooks = hooks.replace(f'%hook {host}', f'@implementation {replacement}')
hooks = hooks.replace('%orig(value);', '[super setSecureTextEntry:value];', 1)
hooks = hooks.replace('%orig(value);', '[super setPreventsCapture:value];', 1)
hooks = hooks.replace('%orig(value, key);', '[super setValue:value forKey:key];')
super_calls = {
    'addSublayer:': 'addSublayer:layer',
    'insertSublayer:atIndex:': 'insertSublayer:layer atIndex:index',
    'insertSublayer:below:': 'insertSublayer:layer below:sibling',
    'insertSublayer:above:': 'insertSublayer:layer above:sibling',
    'replaceSublayer:with:': 'replaceSublayer:oldLayer with:layer',
    'removeFromSuperlayer': 'removeFromSuperlayer',
    'setSublayers:': 'setSublayers:layers',
}

def replace_original(match):
    method = match.group()
    header = method.split('{', 1)[0]
    parts = re.findall(r'(\w+):', header)
    selector = ''.join(part + ':' for part in parts) if parts else header.split(')')[1].strip()
    call = super_calls.get(selector)
    return method.replace('%orig;', f'[super {call}];') if call else method

hooks = re.sub(r'- \(void\).*?(?=\n- \(void\)|\n%end|\Z)', replace_original, hooks, flags=re.S)
hooks = hooks.replace('%end', '@end')

support = r'''
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import "Constants.h"
@interface MemoryCaptureDefaults : NSUserDefaults
@property NSMutableDictionary *values;
@end
@implementation MemoryCaptureDefaults
- (instancetype)init { if ((self = [super init])) self.values = [NSMutableDictionary new]; return self; }
- (BOOL)boolForKey:(NSString *)key { return [self.values[key] boolValue]; }
- (void)setBool:(BOOL)value forKey:(NSString *)key { self.values[key] = @(value); }
- (NSString *)stringForKey:(NSString *)key { return self.values[key]; }
- (void)setObject:(id)value forKey:(NSString *)key { self.values[key] = value; }
@end
@interface CALayer : NSObject {
@public
    NSArray<CALayer *> *_sublayers;
    unsigned int _storedMask;
}
@property(nonatomic, weak) CALayer *superlayer;
@property(nonatomic, strong) NSArray<CALayer *> *sublayers;
@property(nonatomic, strong) CALayer *mask;
@property(nonatomic) unsigned int disableUpdateMask;
@property(nonatomic) NSUInteger maskReadMode;
- (void)setTextCaptureProtected:(BOOL)value;
- (BOOL)isCaptureProtected;
- (void)addSublayer:(CALayer *)layer;
- (void)insertSublayer:(CALayer *)layer atIndex:(unsigned int)index;
- (void)insertSublayer:(CALayer *)layer below:(CALayer *)sibling;
- (void)insertSublayer:(CALayer *)layer above:(CALayer *)sibling;
- (void)replaceSublayer:(CALayer *)oldLayer with:(CALayer *)layer;
- (void)removeFromSuperlayer;
@end
static void detach(CALayer *layer) {
    CALayer *parent = layer.superlayer;
    layer.superlayer = nil;
    NSMutableArray *remaining = [parent.sublayers mutableCopy];
    [remaining removeObjectIdenticalTo:layer];
    if (parent) parent->_sublayers = remaining;
}
@implementation CALayer
@synthesize sublayers = _sublayers;
- (unsigned int)disableUpdateMask {
    if (self.maskReadMode == 2) @throw [NSException exceptionWithName:@"HiddenMask" reason:nil userInfo:nil];
    return self.maskReadMode == 1 ? 0 : _storedMask;
}
- (void)setDisableUpdateMask:(unsigned int)value { _storedMask = value; }
- (void)setTextCaptureProtected:(BOOL)value { _storedMask = (_storedMask & ~0x12u) | (value ? 0x12u : 0); }
- (BOOL)isCaptureProtected { return (_storedMask & 0x12u) != 0; }
- (void)addSublayer:(CALayer *)layer {
    detach(layer);
    layer.superlayer = self;
    _sublayers = [(_sublayers ?: @[]) arrayByAddingObject:layer];
}
- (void)insertSublayer:(CALayer *)layer atIndex:(unsigned int)index {
    detach(layer);
    NSMutableArray *children = [(_sublayers ?: @[]) mutableCopy];
    [children insertObject:layer atIndex:index];
    layer.superlayer = self;
    _sublayers = children;
}
- (void)insertSublayer:(CALayer *)layer below:(CALayer *)sibling {
    [self insertSublayer:layer atIndex:sibling ? (unsigned int)[_sublayers indexOfObjectIdenticalTo:sibling] : 0];
}
- (void)insertSublayer:(CALayer *)layer above:(CALayer *)sibling {
    [self insertSublayer:layer atIndex:sibling ? (unsigned int)[_sublayers indexOfObjectIdenticalTo:sibling] + 1 : (unsigned int)_sublayers.count];
}
- (void)replaceSublayer:(CALayer *)oldLayer with:(CALayer *)layer {
    NSUInteger index = [_sublayers indexOfObjectIdenticalTo:oldLayer];
    detach(oldLayer);
    [self insertSublayer:layer atIndex:(unsigned int)index];
}
- (void)removeFromSuperlayer { detach(self); }
- (void)setSublayers:(NSArray<CALayer *> *)layers {
    for (CALayer *child in _sublayers) child.superlayer = nil;
    _sublayers = @[];
    for (CALayer *child in layers) {
        detach(child);
        child.superlayer = self;
        _sublayers = [_sublayers arrayByAddingObject:child];
    }
}
@end
@interface UIView : NSObject
@property(nonatomic, strong) CALayer *layer;
@property(nonatomic, strong) NSArray<UIView *> *subviews;
@property(nonatomic, weak) id node;
@property(nonatomic) NSUInteger layouts;
@property(nonatomic) NSUInteger windowMoves;
- (id)asyncdisplaykit_node;
- (void)layoutSubviews;
- (void)didMoveToWindow;
@end
@implementation UIView
- (id)asyncdisplaykit_node { return self.node; }
- (void)layoutSubviews { self.layouts++; }
- (void)didMoveToWindow { self.windowMoves++; }
@end
@interface TestGalleryView : UIView @end
@interface TestTextLayoutCanvasView : UIView @end
@interface UITextField : UIView
@property(nonatomic) BOOL secureTextEntry;
@end
@implementation UITextField
- (instancetype)init {
    if ((self = [super init])) {
        UIView *canvas = [TestTextLayoutCanvasView new]; canvas.layer = [CALayer new];
        self.subviews = @[canvas];
    }
    return self;
}
- (void)setSecureTextEntry:(BOOL)value {
    _secureTextEntry = value;
    CALayer *layer = self.subviews.firstObject.layer;
    [layer setTextCaptureProtected:value];
}
@end
@interface AVSampleBufferDisplayLayer : CALayer
@property(nonatomic) BOOL preventsCapture;
@end
@implementation AVSampleBufferDisplayLayer @end
@interface TestTextField : UITextField @end
@interface TestVideoLayer : AVSampleBufferDisplayLayer @end
@interface TestLayer : CALayer @end
@interface TestNode : NSObject
@property(nonatomic, strong) UIView *view;
@property(nonatomic, strong) id footer;
@property(nonatomic) BOOL unlocked;
@property(nonatomic) BOOL secret;
@end
@implementation TestNode @end
@interface TGExtraSecretChatPolicy : NSObject
+ (BOOL)isSecretGalleryItem:(TestNode *)node;
@end
@implementation TGExtraSecretChatPolicy
+ (BOOL)isSecretGalleryItem:(TestNode *)node { return node.secret; }
@end
@interface TGExtraPaidMediaFile : NSObject
+ (id)footerNodeFromItem:(TestNode *)node;
+ (instancetype)fileFromFooterNode:(TestNode *)node;
+ (BOOL)isUnlockedPaidItem:(TestNode *)node;
+ (void)bindGalleryItem:(TestNode *)node;
@end
@implementation TGExtraPaidMediaFile
+ (id)footerNodeFromItem:(TestNode *)node { return node.footer; }
+ (instancetype)fileFromFooterNode:(TestNode *)node { return node.unlocked ? (id)node : nil; }
+ (BOOL)isUnlockedPaidItem:(TestNode *)node { return ((TestNode *)node.footer).unlocked; }
+ (void)bindGalleryItem:(TestNode *)node {}
@end
'''

tests = r'''
static TestNode *item(NSString *name, BOOL unlocked) {
    Class cls = NSClassFromString(name);
    if (!cls) {
        cls = objc_allocateClassPair(TestNode.class, name.UTF8String, 0);
        objc_registerClassPair(cls);
    }
    TestNode *node = [cls new]; node.view = [TestGalleryView new]; node.view.node = node;
    node.view.layer = [TestLayer new];
    TestNode *footer = [TestNode new]; footer.unlocked = unlocked; node.footer = footer;
    return node;
}
static void testReparenting(NSUserDefaults *defaults) {
    for (NSUInteger operation = 0; operation < 14; operation++) {
        [defaults setBool:YES forKey:kDisableForwardRestriction];
        TestNode *gallery = item(@"GalleryUI.UniversalVideoGalleryItemNode", YES);
        TestLayer *player = [TestLayer new];
        CALayer *image = [CALayer new]; image.disableUpdateMask = 0x32;
        TestVideoLayer *video = [TestVideoLayer new]; video.preventsCapture = YES;
        CALayer *unprotected = [CALayer new]; unprotected.disableUpdateMask = 0x20;
        player.sublayers = @[image, video, unprotected];
        [gallery.view.layer addSublayer:player];
        updateGalleryCapture(gallery);
        NSCAssert(image.disableUpdateMask == 0x20 && !video.preventsCapture, @"Paid gallery allows capture");
        if (operation >= 7) [defaults setBool:NO forKey:kDisableForwardRestriction];
        TestLayer *chat = [TestLayer new];
        CALayer *sibling = [CALayer new]; [chat addSublayer:sibling];
        switch (operation % 7) {
            case 0: [chat addSublayer:player]; break;
            case 1: [chat insertSublayer:player atIndex:0]; break;
            case 2: [chat insertSublayer:player below:sibling]; break;
            case 3: [chat insertSublayer:player above:sibling]; break;
            case 4: [chat replaceSublayer:sibling with:player]; break;
            case 5: [player removeFromSuperlayer]; break;
            case 6: chat.sublayers = @[player]; break;
        }
        NSCAssert(image.disableUpdateMask == 0x32 && video.preventsCapture,
                  @"Leaving the gallery restores image and video protection immediately");
        NSCAssert(unprotected.disableUpdateMask == 0x20, @"Reparenting preserves unprotected layers and unrelated bits");
        [defaults setBool:NO forKey:kDisableForwardRestriction];
        updateGalleryCapture(gallery);
        NSCAssert(image.disableUpdateMask == 0x32 && video.preventsCapture, @"Switching off after a move keeps protection");
        [defaults setBool:YES forKey:kDisableForwardRestriction];
        [gallery.view.layer addSublayer:player];
        updateGalleryCapture(gallery);
        NSCAssert(image.disableUpdateMask == 0x20 && !video.preventsCapture, @"Returning to the paid gallery allows capture again");
        TestLayer *otherContainer = [TestLayer new]; [gallery.view.layer addSublayer:otherContainer];
        [otherContainer addSublayer:player];
        NSCAssert(image.disableUpdateMask == 0x20 && !video.preventsCapture, @"Moving within the paid gallery keeps capture allowed");
        if (operation % 2 == 0) otherContainer.sublayers = @[];
        else [otherContainer replaceSublayer:player with:[CALayer new]];
        NSCAssert(image.disableUpdateMask == 0x32 && video.preventsCapture, @"Replacing the parent's sublayers restores removed content");
    }
}
static void testOpaqueCaptureState(NSUserDefaults *defaults) {
    for (NSUInteger mode = 1; mode <= 2; mode++) {
        TestNode *gallery = item(@"GalleryUI.ChatImageGalleryItemNode", YES);
        CALayer *image = [CALayer new]; image.maskReadMode = mode;
        TestTextField *host = [TestTextField new];
        CALayer *ownLayer = host.subviews.firstObject.layer;
        [host.subviews.firstObject setValue:image forKey:@"layer"];
        host.secureTextEntry = NO; host.secureTextEntry = YES;
        [host.subviews.firstObject setValue:ownLayer forKey:@"layer"];
        NSCAssert(image.isCaptureProtected, @"Native protection was applied before the layer entered a paid gallery");
        [defaults setBool:YES forKey:kDisableForwardRestriction];
        [gallery.view.layer addSublayer:image];
        [gallery.view didMoveToWindow];
        NSCAssert(!image.isCaptureProtected, @"Zero or unreadable disableUpdateMask cannot skip clearing real secure protection");
        [defaults setBool:NO forKey:kDisableForwardRestriction];
        [gallery.view layoutSubviews];
        NSCAssert(image.isCaptureProtected, @"Original secure protection restores without reading the private mask");
    }
}
int main(void) {
    @autoreleasepool {
        MemoryCaptureDefaults *memory = [MemoryCaptureDefaults new];
        Method getter = class_getClassMethod(NSUserDefaults.class, @selector(standardUserDefaults));
        method_setImplementation(getter, imp_implementationWithBlock(^id(id cls) { return memory; }));
        NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
        BOOL previous = [defaults boolForKey:kDisableForwardRestriction];
        testReparenting(defaults);
        testOpaqueCaptureState(defaults);
        for (NSString *name in @[@"GalleryUI.ChatImageGalleryItemNode", @"GalleryUI.UniversalVideoGalleryItemNode"]) {
            TestNode *node = item(name, YES);
            CALayer *image = [CALayer new]; image.disableUpdateMask = 0x32;
            TestVideoLayer *video = [TestVideoLayer new]; video.preventsCapture = YES;
            [node.view.layer addSublayer:image]; [node.view.layer addSublayer:video];
            [defaults setBool:NO forKey:kDisableForwardRestriction];
            [node.view didMoveToWindow];
            NSCAssert(node.view.windowMoves == 1, @"Custom gallery view preserves inherited UIView lifecycle");
            NSCAssert(image.disableUpdateMask == 0x32 && video.preventsCapture, @"Switch off preserves both host protections");
            [defaults setBool:YES forKey:kDisableForwardRestriction];
            [node.view layoutSubviews];
            NSCAssert(node.view.layouts == 1, @"UITracingLayerView layout drives capture policy without _ASDisplayView");
            NSCAssert(image.disableUpdateMask == 0x20 && !video.preventsCapture, @"Unlock removes image and video protection, preserving other bits");
            TestVideoLayer *lateVideo = [TestVideoLayer new]; lateVideo.preventsCapture = YES;
            CALayer *crossfade = [CALayer new]; crossfade.disableUpdateMask = 0x12;
            [node.view.layer addSublayer:lateVideo]; [node.view.layer addSublayer:crossfade];
            NSCAssert(!lateVideo.preventsCapture && crossfade.disableUpdateMask == 0, @"Late protected layers are cleared when attached");
            lateVideo.preventsCapture = YES;
            NSCAssert(!lateVideo.preventsCapture, @"Video cannot re-enable capture protection after attachment");
            TestTextField *host = [TestTextField new];
            [host.subviews.firstObject setValue:image forKey:@"layer"];
            host.secureTextEntry = NO; host.secureTextEntry = YES;
            NSCAssert(image.disableUpdateMask == 0x20, @"Telegram's secure-canvas redraw cannot re-enable image protection");
            updateGalleryCapture(node);
            [defaults setBool:NO forKey:kDisableForwardRestriction];
            updateGalleryCapture(node);
            NSCAssert(image.disableUpdateMask == 0x32 && video.preventsCapture && lateVideo.preventsCapture &&
                      crossfade.disableUpdateMask == 0x12, @"Turning off restores original protections, including late arrivals");
            [defaults setBool:YES forKey:kDisableForwardRestriction];
            updateGalleryCapture(node);
            ((TestNode *)node.footer).unlocked = NO;
            updateGalleryCapture(node);
            NSCAssert(image.disableUpdateMask == 0x32 && video.preventsCapture, @"Reused item restores protection when no longer showing unlocked media");
        }
        [defaults setBool:YES forKey:kDisableForwardRestriction];
        for (NSString *name in @[@"GalleryUI.ChatImageGalleryItemNode", @"GalleryUI.UniversalVideoGalleryItemNode", @"Other.SecretMediaNode"]) {
            TestNode *node = item(name, NO);
            CALayer *layer = [CALayer new]; layer.disableUpdateMask = 0x12;
            [node.view.layer addSublayer:layer]; updateGalleryCapture(node);
            NSCAssert(layer.disableUpdateMask == 0x12, @"Locked, ordinary and secret-media screens stay protected");
        }
        for (NSString *name in @[@"GalleryUI.ChatImageGalleryItemNode", @"GalleryUI.UniversalVideoGalleryItemNode"]) {
            TestNode *secret = item(name, NO); secret.secret = YES;
            CALayer *image = [CALayer new]; image.disableUpdateMask = 0x32;
            TestVideoLayer *video = [TestVideoLayer new]; video.preventsCapture = YES;
            secret.view.layer.sublayers = @[image, video];
            [defaults setBool:NO forKey:kDisableForwardRestriction];
            [defaults setBool:YES forKey:kDisableScreenshotNotification];
            updateGalleryCapture(secret);
            NSCAssert(image.disableUpdateMask == 0x20 && !video.preventsCapture, @"Secret gallery has its own screenshot setting");
            TestTextField *redraw = [TestTextField new];
            [redraw.subviews.firstObject setValue:image forKey:@"layer"];
            redraw.secureTextEntry = YES;
            NSCAssert(image.disableUpdateMask == 0x20, @"Secret image redraw stays capturable");
            [defaults setBool:NO forKey:kDisableScreenshotNotification];
            updateGalleryCapture(secret);
            NSCAssert(image.disableUpdateMask == 0x32 && video.preventsCapture, @"Turning off secret capture restores host protection");
            [defaults setBool:YES forKey:kDisableScreenshotNotification];
            updateGalleryCapture(secret);
            secret.secret = NO;
            updateGalleryCapture(secret);
            NSCAssert(image.disableUpdateMask == 0x32 && video.preventsCapture, @"Reusing a secret gallery for ordinary media restores protection");
        }
        TestTextField *password = [TestTextField new]; password.secureTextEntry = YES;
        NSCAssert(password.secureTextEntry && password.subviews.firstObject.layer.disableUpdateMask == 0x12,
                  @"Ordinary password fields retain secure text entry");
        [defaults setBool:previous forKey:kDisableForwardRestriction];
        puts("PASS paid-gallery capture: photo/video, reparenting, late layers, redraws, off/on/off, reuse and unrelated secure fields");
    }
}
'''

with tempfile.TemporaryDirectory(prefix='tgextra-paid-capture-') as directory:
    path = Path(directory)
    harness = path / 'capture.mm'
    harness.write_text(re.sub(r'\bCALayer\b', 'MockCaptureLayer', support + helpers + view_hook + hooks + tests))
    binary = path / 'tests'
    subprocess.run(['clang++', '-fobjc-arc', '-Werror', '-I', str(root / 'Sources/tgapi'),
                    '-framework', 'Foundation', str(harness), '-o', str(binary)], check=True)
    subprocess.run([str(binary)], check=True, timeout=30)
