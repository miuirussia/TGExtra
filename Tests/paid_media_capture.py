#!/usr/bin/env python3
"""Exercise production capture policy with UIKit/CoreAnimation stand-ins."""
from pathlib import Path
import re
import subprocess
import tempfile

root = Path(__file__).resolve().parent.parent
source = (root / 'Sources/tgapi/PaidMediaCapture.xm').read_text()
helpers = source[source.index('static char paidCaptureRootKey'):source.index('%hook UITextField')]
hooks = source[source.index('%hook UITextField'):]
for host, replacement in [('UITextField', 'TestTextField'),
                          ('AVSampleBufferDisplayLayer', 'TestVideoLayer'), ('CALayer', 'TestLayer')]:
    hooks = hooks.replace(f'%hook {host}', f'@implementation {replacement}')
hooks = hooks.replace('%orig(value);', '[super setSecureTextEntry:value];', 1)
hooks = hooks.replace('%orig(value);', '[super setPreventsCapture:value];', 1)
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
@property BOOL enabled;
@end
@implementation MemoryCaptureDefaults
- (BOOL)boolForKey:(NSString *)key { return self.enabled; }
- (void)setBool:(BOOL)value forKey:(NSString *)key { self.enabled = value; }
@end
@interface CALayer : NSObject {
@public
    NSArray<CALayer *> *_sublayers;
}
@property(nonatomic, weak) CALayer *superlayer;
@property(nonatomic, strong) NSArray<CALayer *> *sublayers;
@property(nonatomic, strong) CALayer *mask;
@property(nonatomic) unsigned int disableUpdateMask;
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
@end
@implementation UIView
@end
@interface TestTextLayoutCanvasView : UIView @end
@implementation TestTextLayoutCanvasView @end
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
    layer.disableUpdateMask = (layer.disableUpdateMask & ~0x12u) | (value ? 0x12u : 0);
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
@end
@implementation TestNode @end
@interface TGExtraPaidMediaFile : NSObject
+ (id)footerNodeFromItem:(TestNode *)node;
+ (instancetype)fileFromFooterNode:(TestNode *)node;
@end
@implementation TGExtraPaidMediaFile
+ (id)footerNodeFromItem:(TestNode *)node { return node.footer; }
+ (instancetype)fileFromFooterNode:(TestNode *)node { return node.unlocked ? (id)node : nil; }
@end
'''

tests = r'''
static TestNode *item(NSString *name, BOOL unlocked) {
    Class cls = NSClassFromString(name);
    if (!cls) {
        cls = objc_allocateClassPair(TestNode.class, name.UTF8String, 0);
        objc_registerClassPair(cls);
    }
    TestNode *node = [cls new]; node.view = [UIView new]; node.view.layer = [TestLayer new];
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
        TGExtraUpdatePaidMediaCapture(gallery);
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
        TGExtraUpdatePaidMediaCapture(gallery);
        NSCAssert(image.disableUpdateMask == 0x32 && video.preventsCapture, @"Switching off after a move keeps protection");
        [defaults setBool:YES forKey:kDisableForwardRestriction];
        [gallery.view.layer addSublayer:player];
        TGExtraUpdatePaidMediaCapture(gallery);
        NSCAssert(image.disableUpdateMask == 0x20 && !video.preventsCapture, @"Returning to the paid gallery allows capture again");
        TestLayer *otherContainer = [TestLayer new]; [gallery.view.layer addSublayer:otherContainer];
        [otherContainer addSublayer:player];
        NSCAssert(image.disableUpdateMask == 0x20 && !video.preventsCapture, @"Moving within the paid gallery keeps capture allowed");
        if (operation % 2 == 0) otherContainer.sublayers = @[];
        else [otherContainer replaceSublayer:player with:[CALayer new]];
        NSCAssert(image.disableUpdateMask == 0x32 && video.preventsCapture, @"Replacing the parent's sublayers restores removed content");
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
        for (NSString *name in @[@"GalleryUI.ChatImageGalleryItemNode", @"GalleryUI.UniversalVideoGalleryItemNode"]) {
            TestNode *node = item(name, YES);
            CALayer *image = [CALayer new]; image.disableUpdateMask = 0x32;
            TestVideoLayer *video = [TestVideoLayer new]; video.preventsCapture = YES;
            [node.view.layer addSublayer:image]; [node.view.layer addSublayer:video];
            [defaults setBool:NO forKey:kDisableForwardRestriction];
            TGExtraUpdatePaidMediaCapture(node);
            NSCAssert(image.disableUpdateMask == 0x32 && video.preventsCapture, @"Switch off preserves both host protections");
            [defaults setBool:YES forKey:kDisableForwardRestriction];
            TGExtraUpdatePaidMediaCapture(node);
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
            TGExtraUpdatePaidMediaCapture(node);
            [defaults setBool:NO forKey:kDisableForwardRestriction];
            TGExtraUpdatePaidMediaCapture(node);
            NSCAssert(image.disableUpdateMask == 0x32 && video.preventsCapture && lateVideo.preventsCapture &&
                      crossfade.disableUpdateMask == 0x12, @"Turning off restores original protections, including late arrivals");
            [defaults setBool:YES forKey:kDisableForwardRestriction];
            TGExtraUpdatePaidMediaCapture(node);
            ((TestNode *)node.footer).unlocked = NO;
            TGExtraUpdatePaidMediaCapture(node);
            NSCAssert(image.disableUpdateMask == 0x32 && video.preventsCapture, @"Reused item restores protection when no longer showing unlocked media");
        }
        [defaults setBool:YES forKey:kDisableForwardRestriction];
        for (NSString *name in @[@"GalleryUI.ChatImageGalleryItemNode", @"GalleryUI.UniversalVideoGalleryItemNode", @"Other.SecretMediaNode"]) {
            TestNode *node = item(name, NO);
            CALayer *layer = [CALayer new]; layer.disableUpdateMask = 0x12;
            [node.view.layer addSublayer:layer]; TGExtraUpdatePaidMediaCapture(node);
            NSCAssert(layer.disableUpdateMask == 0x12, @"Locked, ordinary and secret-media screens stay protected");
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
    harness.write_text(re.sub(r'\bCALayer\b', 'MockCaptureLayer', support + helpers + hooks + tests))
    binary = path / 'tests'
    subprocess.run(['clang++', '-fobjc-arc', '-Werror', '-I', str(root / 'Sources/tgapi'),
                    '-framework', 'Foundation', str(harness), '-o', str(binary)], check=True)
    subprocess.run([str(binary)], check=True, timeout=30)
