#!/usr/bin/env python3
"""Exercise settings insertion and host geometry through real UIKit on macOS."""
from pathlib import Path
import platform
import subprocess
import sys
import tempfile

if sys.platform != 'darwin':
    print('SKIP settings menu: Mac Catalyst requires macOS')
    sys.exit(0)

sdk = Path(subprocess.check_output(['xcrun', '--sdk', 'macosx', '--show-sdk-path'], text=True).strip())
frameworks = sdk / 'System/iOSSupport/System/Library/Frameworks'
if not (frameworks / 'UIKit.framework/Headers/UIKit.h').exists():
    print('SKIP settings menu: set DEVELOPER_DIR to Xcode with Mac Catalyst')
    sys.exit(0)

root = Path(__file__).resolve().parent.parent
source = (root / 'Sources/tgapi/UI/SettingsMenu.xm').read_text()
button = (root / 'Sources/tgapi/UI/SettingsMenuButton.m').read_text()
button = button.replace('#import "SettingsNavigation.h"', '''
static NSUInteger opens;
void TGExtraShowSettings(void) { opens++; }
BOOL TGExtraIsTelegramSupportLabel(NSString *label) { return [label isEqualToString:@"Ask a Question"]; }
BOOL TGExtraIsMyProfileLabel(NSString *label) { return [label isEqualToString:@"My Profile"]; }
''')
host_header = (root / 'Sources/tgapi/UI/HostDisplayNode.h').read_text().split('@interface UIView')[0]
button_header = (root / 'Sources/tgapi/UI/SettingsMenuButton.h').read_text()
helpers = host_header + button_header + button + source[:source.index('%group TGExtraSettingsMenu')]
helpers = helpers.replace('#import "HostDisplayNode.h"', '').replace('#import "SettingsMenuButton.h"', '')
geometry = source[source.index('%hook ASDisplayNode'):source.index('%hook ASScrollView')]
geometry = geometry.replace('%hook ASDisplayNode', '@interface LayoutNode : ASDisplayNode @end\n@implementation LayoutNode')
geometry = geometry.replace('%end', '@end')
frame_hooks, position_hooks = geometry.split('- (CGPoint)position', 1)
frame_hooks = frame_hooks.replace('%orig(frame)', '[super setFrame:frame]').replace('%orig', '[super frame]')
position_hooks = position_hooks.replace('%orig(position)', '[super setPosition:position]').replace('%orig', '[super position]')
geometry = frame_hooks + '- (CGPoint)position' + position_hooks

mocks = r'''
@interface ASDisplayNode ()
@property (nonatomic, strong) UIView *backingView;
@property (nonatomic, weak) ASDisplayNode *parentNode;
@property (nonatomic, copy) NSArray<ASDisplayNode *> *children;
@property (nonatomic, copy) NSString *label;
@end
@implementation ASDisplayNode
- (UIView *)view { if (!_backingView) _backingView = [UIView new]; return _backingView; }
- (CALayer *)layer { return self.view.layer; }
- (ASDisplayNode *)supernode { return self.parentNode; }
- (NSArray *)subnodes { return self.children ?: @[]; }
- (NSString *)accessibilityLabel { return self.label; }
- (void)setAccessibilityLabel:(NSString *)label { self.label = label; }
- (void)setNeedsLayout { [self.view setNeedsLayout]; }
- (void)layoutIfNeeded { [self.view layoutIfNeeded]; }
- (BOOL)isHidden { return self.view.hidden; }
- (CGFloat)alpha { return self.view.alpha; }
- (UIColor *)backgroundColor { return self.view.backgroundColor; }
- (CGPoint)position { return self.view.center; }
- (void)setPosition:(CGPoint)position { self.view.center = position; }
- (CGRect)frame {
    CGPoint p = self.position;
    CGSize s = self.view.bounds.size;
    return CGRectMake(p.x - s.width / 2, p.y - s.height / 2, s.width, s.height);
}
- (void)setFrame:(CGRect)frame {
    self.view.bounds = (CGRect){CGPointZero, frame.size};
    self.position = CGPointMake(CGRectGetMidX(frame), CGRectGetMidY(frame));
}
@end
// Display.ASImageNode stores its image in Swift; Objective-C can only read
// the rendered CALayer contents, not an `image` selector.
@interface ASImageNode : ASDisplayNode
@property (nonatomic, strong) UIImage *testImage;
@property (nonatomic) CGRect layoutFrame;
@end
@implementation ASImageNode
- (instancetype)init {
    if ((self = [super init])) self.backingView = [UIView new];
    return self;
}
- (CGRect)frame { return self.layoutFrame; }
- (void)setFrame:(CGRect)frame { self.layoutFrame = frame; [super setFrame:frame]; }
- (void)setTestImage:(UIImage *)image {
    _testImage = image;
    CALayer *layer = self.layer;
    layer.contents = (__bridge id)image.CGImage;
    layer.contentsScale = image.scale;
    CGSize size = image.size;
    UIEdgeInsets insets = image.capInsets;
    CGRect center = CGRectMake(0, 0, 1, 1);
    if (insets.left || insets.right) {
        center.origin.x = (insets.left + 0.49) / size.width;
        center.size.width = (size.width - insets.left - insets.right - 0.98) / size.width;
    }
    if (insets.top || insets.bottom) {
        center.origin.y = (insets.top + 0.49) / size.height;
        center.size.height = (size.height - insets.top - insets.bottom - 0.98) / size.height;
    }
    layer.contentsCenter = center;
}
@end
@interface ASScrollView ()
@property (nonatomic, strong) ASDisplayNode *node;
@end
@implementation ASScrollView
- (ASDisplayNode *)scrollNode { return self.node; }
@end
'''

tests = r'''
static ASDisplayNode *node(NSString *name, CGRect frame) {
    Class cls = objc_getClass(name.UTF8String);
    if (!cls) { cls = objc_allocateClassPair(LayoutNode.class, name.UTF8String, 0); objc_registerClassPair(cls); }
    ASDisplayNode *n = [cls new]; n.frame = frame; return n;
}
static void children(ASDisplayNode *parent, NSArray *nodes) {
    for (ASDisplayNode *n in parent.children) [n.view removeFromSuperview];
    parent.children = nodes;
    for (ASDisplayNode *n in nodes) { n.parentNode = parent; [parent.view addSubview:n.view]; }
}
static ASDisplayNode *section(NSString *label, CGFloat y, CGFloat height) {
    ASDisplayNode *section = node(@"TelegramUI.PeerInfoScreenItemSectionContainerNode", CGRectMake(16, y, 358, height));
    ASDisplayNode *container = node(@"Container", CGRectMake(0, 0, 358, height));
    ASDisplayNode *row = node(@"TelegramUI.PeerInfoScreenDisclosureItemNode", CGRectMake(0, 0, 358, 52));
    ASDisplayNode *area = node(@"Display.AccessibilityAreaNode", CGRectMake(0, 0, 358, 52));
    area.label = label;
    children(row, @[area]); children(container, @[row]); children(section, @[container]);
    return section;
}
static UIImage *cornerImage(BOOL top, BOOL bottom, UIColor *background) {
    UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:CGSizeMake(56, 56)];
    return [[renderer imageWithActions:^(UIGraphicsImageRendererContext *context) {
        [background setFill];
        UIRectFill(CGRectMake(0, 0, 56, 56));
        CGContextSetBlendMode(context.CGContext, kCGBlendModeClear);
        UIRectCorner corners = 0;
        if (top) corners |= UIRectCornerTopLeft | UIRectCornerTopRight;
        if (bottom) corners |= UIRectCornerBottomLeft | UIRectCornerBottomRight;
        [[UIBezierPath bezierPathWithRoundedRect:CGRectMake(0, 0, 56, 56) byRoundingCorners:corners
                                   cornerRadii:CGSizeMake(26, 26)] fill];
    }] stretchableImageWithLeftCapWidth:28 topCapHeight:28];
}
static ASImageNode *cornerMask(ASDisplayNode *section) {
    ASDisplayNode *row = section.children[0].children[0];
    ASImageNode *mask = [ASImageNode new];
    mask.frame = row.view.bounds;
    mask.testImage = cornerImage(YES, YES, UIColor.blackColor);
    mask.view.userInteractionEnabled = NO;
    children(row, [row.children arrayByAddingObject:mask]);
    return mask;
}
static CGFloat brightness(UIView *view, CGPoint point) {
    unsigned char pixel[4] = {0};
    CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
    CGContextRef context = CGBitmapContextCreate(pixel, 1, 1, 8, 4, space, (CGBitmapInfo)kCGImageAlphaPremultipliedLast);
    CGContextTranslateCTM(context, -point.x, -point.y);
    [view.layer renderInContext:context];
    CGContextRelease(context);
    CGColorSpaceRelease(space);
    return (pixel[0] + pixel[1] + pixel[2]) / (3.0 * 255.0);
}
int main(void) { @autoreleasepool {
    ASScrollView *scroll = [[ASScrollView alloc] initWithFrame:CGRectMake(0, 0, 390, 1400)];
    ASDisplayNode *screen = node(@"TelegramUI.PeerInfoScreenNode", CGRectMake(0, 0, 390, 1400));
    ASDisplayNode *root = node(@"ScrollNode", CGRectMake(0, 0, 390, 1400));
    children(screen, @[root]); scroll.node = root; [scroll addSubview:root.view];
    ASDisplayNode *profile = section(@"My Profile", 200, 52);
    ASDisplayNode *standard = section(@"Notifications", 276, 156);
    ASDisplayNode *support = section(@"Ask a Question", 900, 156);
    children(root, @[profile, standard, support]);
    CGSize size = TGExtraSettingsContentSize(scroll, CGSizeMake(390, 1100));
    TGExtraSettingsButton *button = objc_getAssociatedObject(scroll, &TGExtraSettingsButtonKey);
    NSCAssert(!button.hidden && button.frame.origin.y == 276, @"Telegram: directly below My Profile");
    NSCAssert(size.height == 1176 && standard.view.frame.origin.y == 352, @"Reserve one row plus section spacing");
    NSCAssert(button.frame.origin.y - CGRectGetMaxY(profile.view.frame) == 24 &&
              standard.view.frame.origin.y - CGRectGetMaxY(button.frame) == 24, @"Telegram has spacing above and below TGExtra");
    NSCAssert(button.topSeparator.hidden && button.layer.maskedCorners == 15, @"Telegram keeps an independent rounded section");
    NSCAssert(standard.frame.origin.y == 276 && standard.position.y == 354, @"Host geometry stays unchanged");
    UIButton *nativeControl = [[UIButton alloc] initWithFrame:CGRectMake(0, 0, 358, 52)];
    [standard.view addSubview:nativeControl];
    CGPoint nativePoint = [nativeControl convertPoint:CGPointMake(100, 26) toView:scroll];
    NSCAssert([scroll hitTest:nativePoint withEvent:nil] == nativeControl, @"Native buttons remain tappable at their shifted visual position");
    CGPoint tweakPoint = [button convertPoint:CGPointMake(100, 26) toView:scroll];
    NSCAssert([scroll hitTest:tweakPoint withEvent:nil] == button, @"TGExtra is tappable in its reserved space");
    for (int i = 0; i < 10; i++) {
        size = TGExtraSettingsContentSize(scroll, CGSizeMake(390, 1100));
        NSCAssert(size.height == 1176 && support.view.frame.origin.y == 976, @"Repeated layout cannot accumulate offsets");
    }
    standard.frame = CGRectMake(16, 280, 358, 156);
    NSCAssert(standard.view.frame.origin.y == 356 && standard.frame.origin.y == 280, @"Host frame writes preserve visual offset");
    standard.position = CGPointMake(195, 358);
    NSCAssert(standard.view.center.y == 434 && standard.position.y == 358, @"Host position writes preserve visual offset");

    ASDisplayNode *sg = section(@"Swiftgram", 300, 52);
    ASDisplayNode *pro = section(@"Swiftgram Pro", 376, 52);
    ASImageNode *sgMask = cornerMask(sg);
    ASImageNode *proMask = cornerMask(pro);
    NSCAssert(![proMask respondsToSelector:NSSelectorFromString(@"image")], @"Match the host Swift image node without an Objective-C image getter");
    // Texture layout frames can be ready before backing-layer bounds are committed.
    proMask.layer.bounds = CGRectZero;
    standard.frame = CGRectMake(16, 452, 358, 156);
    children(root, @[profile, pro, sg, standard, support]);
    TGExtraSettingsContentSize(scroll, CGSizeMake(390, 1100));
    NSCAssert(button.frame.origin.y == 428 && standard.view.frame.origin.y == 504, @"Join the bottom of the final Swiftgram section without a gap");
    NSCAssert(standard.view.frame.origin.y - CGRectGetMaxY(button.frame) == 24, @"Preserve spacing after the joined Swiftgram section");
    NSCAssert(!button.topSeparator.hidden && button.layer.maskedCorners == (kCALayerMinXMaxYCorner | kCALayerMaxXMaxYCorner), @"Joined row has a separator and only lower rounded corners");
    NSCAssert(proMask.layer.mask != nil && proMask.layer.mask.frame.size.height == 26, @"Preserve Swiftgram's upper corners while opening the lower corners");
    NSCAssert(proMask.layer.mask.frame.size.width == 358, @"Use layout size while backing-layer bounds are still pending");
    proMask.frame = proMask.layoutFrame;
    NSCAssert(button.cornerOverlay.layer.contents == proMask.layer.contents &&
              CGRectEqualToRect(button.cornerOverlay.layer.contentsCenter, proMask.layer.contentsCenter) &&
              button.layer.cornerRadius == 0, @"Use the native corner image instead of an approximate radius");
    [button layoutIfNeeded];
    pro.view.backgroundColor = UIColor.whiteColor;
    button.backgroundColor = UIColor.whiteColor;
    NSCAssert(brightness(pro.view, CGPointMake(1, 1)) < 0.1 &&
              brightness(pro.view, CGPointMake(1, 50)) > 0.9, @"Native upper corners remain rounded and the join has no lower cutouts");
    NSCAssert(brightness(button, CGPointMake(1, 1)) > 0.9 &&
              brightness(button, CGPointMake(1, 50)) < 0.1, @"TGExtra continues the surface with native lower corners");
    NSCAssert(sg.view.frame.origin.y == 300 && pro.view.frame.origin.y == 376, @"Leave Swiftgram rows in place");
    pro.view.hidden = YES;
    TGExtraSettingsContentSize(scroll, CGSizeMake(390, 1100));
    NSCAssert(button.frame.origin.y == 352 && proMask.layer.mask == nil && sgMask.layer.mask != nil, @"Restore the old corner mask when joining another Swiftgram section");
    NSCAssert([[button actionsForTarget:button forControlEvent:UIControlEventTouchUpInside] containsObject:@"openMenu"], @"Keep the button action wired");
    [button openMenu];
    NSCAssert(opens == 1, @"Menu still opens from the relocated button");

    UIAccessibilityElement *before = [[UIAccessibilityElement alloc] initWithAccessibilityContainer:scroll];
    UIAccessibilityElement *after = [[UIAccessibilityElement alloc] initWithAccessibilityContainer:scroll];
    before.accessibilityFrame = CGRectMake(0, 100, 100, 40);
    after.accessibilityFrame = CGRectMake(0, 10000, 100, 40);
    button.accessibilityFrame = button.frame;
    NSArray *elements = TGExtraSettingsAccessibilityElements(scroll, @[before, button, after]);
    NSCAssert(([elements isEqualToArray:@[before, button, after]]), @"VoiceOver follows visual order without duplicates");

    profile.view.alpha = 0;
    size = TGExtraSettingsContentSize(scroll, CGSizeMake(390, 1100));
    NSCAssert(button.hidden && size.height == 1100, @"Hide in edit mode when My Profile is absent");
    NSCAssert(standard.view.frame.origin.y == 452 && support.view.frame.origin.y == 900, @"Restore all native positions when inactive");
    NSCAssert(sgMask.layer.mask == nil && proMask.layer.mask == nil, @"Restore native Swiftgram corners when inactive");
    profile.view.alpha = 1;
    ASDisplayNode *combined = section(@"Swiftgram Pro", 300, 104);
    ASDisplayNode *lastSection = section(@"Swiftgram", 0, 52);
    ASImageNode *firstMask = cornerMask(combined);
    ASImageNode *lastMask = cornerMask(lastSection);
    ASDisplayNode *lastRow = lastSection.children[0].children[0];
    lastRow.frame = CGRectMake(0, 52, 358, 52);
    children(combined.children[0], @[combined.children[0].children[0], lastRow]);
    children(root, @[profile, combined, standard, support]);
    TGExtraSettingsContentSize(scroll, CGSizeMake(390, 1100));
    NSCAssert(button.frame.origin.y == 404 && button.joinedMaskNode == lastMask && firstMask.layer.mask == nil, @"Join the final row of a shared Swiftgram/Pro group, preserving its first row");
    for (NSNumber *dark in @[@NO, @YES]) {
        UIColor *surface = dark.boolValue ? UIColor.blackColor : UIColor.whiteColor;
        UIColor *background = dark.boolValue ? UIColor.whiteColor : UIColor.blackColor;
        firstMask.testImage = cornerImage(YES, NO, background);
        lastMask.testImage = cornerImage(NO, YES, background);
        combined.view.backgroundColor = surface;
        TGExtraSettingsContentSize(scroll, CGSizeMake(390, 1100));
        button.backgroundColor = surface;
        [button layoutIfNeeded];
        CGFloat expectedSurface = dark.boolValue ? 0.0 : 1.0;
        for (NSNumber *x in @[@1, @357]) {
            NSCAssert(fabs(brightness(combined.view, CGPointMake(x.doubleValue, 103)) - expectedSurface) < 0.1 &&
                      fabs(brightness(button, CGPointMake(x.doubleValue, 1)) - expectedSurface) < 0.1,
                      @"Shared Swiftgram/Pro group has a straight join on both sides in either theme");
            NSCAssert(fabs(brightness(button, CGPointMake(x.doubleValue, 50)) - (1.0 - expectedSurface)) < 0.1,
                      @"Move native bottom-only corner cutouts to the final TGExtra row in either theme");
        }
    }
    children(root, @[profile, standard, support]);
    TGExtraSettingsContentSize(scroll, CGSizeMake(390, 1100));
    NSCAssert(button.frame.origin.y == 276 && button.topSeparator.hidden && button.layer.maskedCorners == 15 && lastMask.layer.mask == nil, @"Return to a separate Telegram block after Swiftgram rows disappear");
    for (CGFloat width = 375; width <= 812; width += 437) {
        support.children[0].children[0].frame = CGRectMake(0, 0, width - 32, 52);
        TGExtraSettingsContentSize(scroll, CGSizeMake(width, 1100));
        NSCAssert(button.frame.size.width == width - 32, @"Adapt to small phones and landscape");
    }
    root.parentNode = nil;
    size = TGExtraSettingsContentSize(scroll, CGSizeMake(390, 1100));
    NSCAssert(button.hidden && size.height == 1100 && support.view.frame.origin.y == 900, @"Unrelated screens restore layout and have no tweak entry");
    puts("PASS UIKit settings placement, Swift image layers, joined corners in both themes, repeated layout, resizing, edit mode, VoiceOver and opening");
} }
'''

with tempfile.TemporaryDirectory(prefix='tgextra-settings-menu-') as tmp:
    harness = Path(tmp) / 'menu.m'
    harness.write_text(helpers + mocks + geometry + tests)
    binary = Path(tmp) / 'menu'
    subprocess.run([
        'xcrun', 'clang', '-target', f'{platform.machine()}-apple-ios15.0-macabi',
        '-isysroot', str(sdk), '-iframework', str(frameworks), '-fobjc-arc',
        '-Werror', '-Wno-deprecated-declarations', '-framework', 'UIKit',
        '-framework', 'Foundation', '-framework', 'QuartzCore', '-framework', 'CoreGraphics',
        str(harness), '-o', str(binary),
    ], check=True)
    subprocess.run([str(binary)], check=True)
