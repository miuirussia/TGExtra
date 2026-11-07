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
source = (root / 'Sources/tgapi/UI/SettingsMenu.x').read_text()
button = (root / 'Sources/tgapi/UI/SettingsMenuButton.m').read_text()
button = button.replace('#import "SettingsNavigation.h"', '''
static NSUInteger opens;
static id openedSource;
void TGExtraShowSettings(id source) { opens++; openedSource = source; }
BOOL TGExtraIsTelegramSupportLabel(NSString *label) { return [label isEqualToString:@"Ask a Question"]; }
BOOL TGExtraIsMyProfileLabel(NSString *label) { return [label isEqualToString:@"My Profile"]; }
''')
host_header = (root / 'Sources/tgapi/UI/HostDisplayNode.h').read_text().split('@interface UIView')[0]
button_header = (root / 'Sources/tgapi/UI/SettingsMenuButton.h').read_text()
helpers = host_header + button_header + button + source[:source.index('%group TGExtraSettingsMenu')]
helpers = helpers.replace('#import "HostDisplayNode.h"', '').replace('#import "SettingsMenuButton.h"', '')
profile = (root / 'Sources/tgapi/UI/ProfileInfoRow.m').read_text()
helpers = helpers.replace('#import "ProfileInfoRow.h"', '')
profile = profile.replace('#import "ProfileInfoRow.h"', '')
profile = profile.replace('#import "ProfileBridge.h"', (root / 'Sources/tgapi/UI/ProfileBridge.h').read_text())
profile = profile.replace('#import "TGExtraLocalization.h"', (root / 'Sources/tgapi/UI/TGExtraLocalization.h').read_text())
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
@property (nonatomic, copy) NSDictionary *fields;
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

profile_mocks = r'''
static BOOL showProfileInfo = YES;
@implementation TGExtraProfileBridge
+ (id)sharedContext { return nil; }
+ (void)setSharedContext:(id)context {}
+ (NSNumber *)getPeerIdFromNode:(ASDisplayNode *)node { return node.fields[@"peerId"]; }
+ (id)getTitleNodeFromNode:(id)node { return nil; }
+ (BOOL)isMutualContactFromNode:(id)node { return NO; }
+ (BOOL)shouldShowProfileInfoFromNode:(id)node { return showProfileInfo; }
+ (NSNumber *)getPaneOriginFromNode:(ASDisplayNode *)node contentHeight:(double)height { return node.fields[@"paneOrigin"]; }
+ (id)getInfoSectionFromNode:(ASDisplayNode *)node { return node.fields[@"infoSection"]; }
+ (id)getStoredField:(NSString *)field fromNode:(ASDisplayNode *)node { return node.fields[field]; }
+ (NSNumber *)getOwnUserIdFromNode:(id)node { return @42; }
+ (NSNumber *)getCurrentUserId { return @42; }
+ (NSDictionary *)getPeerDisplayInfoFromNode:(id)node { return @{}; }
+ (NSString *)debugPeerCandidates:(id)node { return @""; }
@end
@implementation TGExtraLocalization
@dynamic localization, languageCode;
+ (instancetype)shared { return nil; }
+ (NSString *)localizedStringForKey:(NSString *)key { return key; }
@end
static NSString *lastToast;
void TGExtraShowToast(NSString *text) { lastToast = text; }
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
    NSCAssert(opens == 1 && openedSource == screen, @"Menu retains the actual account's native profile screen");

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
    ASDisplayNode *profileScreen = node(@"TelegramUI.PeerInfoScreenNode", CGRectMake(0, 0, 390, 1100));
    children(profileScreen, @[root]);
    ASDisplayNode *info = node(@"TelegramUI.PeerInfoScreenItemSectionContainerNode", CGRectMake(16, 300, 358, 120));
    ASDisplayNode *labeled = node(@"TelegramUI.PeerInfoScreenLabeledValueItemNode", CGRectMake(0, 60, 358, 60));
    ASImageNode *infoMask = [ASImageNode new];
    infoMask.frame = labeled.frame;
    infoMask.testImage = cornerImage(NO, YES, UIColor.whiteColor);
    labeled.fields = @{@"maskNode": infoMask};
    children(info, @[labeled]);
    children(root, @[info, standard]);
    standard.frame = CGRectMake(16, 444, 358, 200);
    profileScreen.fields = @{@"peerId": @7331000001, @"infoSection": info};
    size = TGExtraProfileInfoContentSize(scroll, root, CGSizeMake(390, 1100));
    TGExtraProfileInfoRow *idRow = objc_getAssociatedObject(scroll, &profileInfoRowKey);
    [idRow layoutIfNeeded];
    NSCAssert(size.height >= 1160 && idRow.frame.origin.y == 420 && [idRow.value.text isEqualToString:@"7331000001"],
              @"Append the full 64-bit profile ID to the information group");
    NSCAssert(standard.frame.origin.y == 444 && standard.view.frame.origin.y == 444 + idRow.frame.size.height,
              @"Reserve room without changing the host's layout coordinates");
    NSCAssert(infoMask.layer.mask != nil && idRow.corners.layer.contents != nil, @"Move native bottom corners to the appended row");
    CGSize repeated = TGExtraProfileInfoContentSize(scroll, root, CGSizeMake(390, 1100));
    NSCAssert(CGSizeEqualToSize(size, repeated), @"Repeated layout cannot accumulate inserted height");
    NSCAssert([[idRow actionsForTarget:idRow forControlEvent:UIControlEventTouchUpInside] containsObject:@"copyId"], @"Wire the copy action to taps");
    [idRow copyId];
    NSCAssert([UIPasteboard.generalPasteboard.string isEqualToString:@"7331000001"] && lastToast.length,
              @"Tapping copies the ID with confirmation");
    NSArray *profileElements = TGExtraProfileInfoAccessibilityElements(scroll, @[]);
    NSCAssert([profileElements containsObject:idRow] && idRow.accessibilityValue.length, @"Expose the ID and copy action to VoiceOver");
    ASDisplayNode *items = node(@"ProfileItemContainerNode", CGRectMake(0, 0, 358, 208));
    items.view.clipsToBounds = YES;
    ASDisplayNode *infoBackground = node(@"ProfileBackgroundNode", CGRectMake(0, 0, 358, 208));
    ASDisplayNode *infoBottom = node(@"ProfileBottomSeparatorNode", CGRectMake(0, 208, 358, 1));
    ASDisplayNode *addContact = node(@"TelegramUI.PeerInfoScreenActionItemNode", CGRectMake(0, 120, 358, 44));
    ASDisplayNode *blockUser = node(@"TelegramUI.PeerInfoScreenActionItemNode", CGRectMake(0, 164, 358, 44));
    children(items, @[labeled, addContact, blockUser]);
    children(info, @[infoBackground, items, infoBottom]);
    info.fields = @{@"itemContainerNode": items, @"backgroundNode": infoBackground, @"bottomSeparatorNode": infoBottom};
    info.frame = CGRectMake(16, 300, 358, 208);
    standard.frame = CGRectMake(16, 532, 358, 200);
    size = TGExtraProfileInfoContentSize(scroll, root, CGSizeMake(390, 1188));
    NSCAssert(idRow.frame.origin.y == 420 && addContact.view.frame.origin.y == 120 + idRow.frame.size.height &&
              blockUser.view.frame.origin.y == 164 + idRow.frame.size.height, @"Insert ID before Add to Contacts and Block User inside the information section");
    NSCAssert(info.frame.size.height == 208 && info.view.frame.size.height == 208 + idRow.frame.size.height &&
              items.view.bounds.size.height == 208 + idRow.frame.size.height && infoBackground.view.frame.size.height == 208 + idRow.frame.size.height,
              @"Extend native backgrounds and clipping containers while preserving host geometry");
    NSCAssert(idRow.layer.cornerRadius == 0 && !idRow.bottomSeparator.hidden && infoMask.layer.mask == nil,
              @"An ID between details and actions has separators and straight sides, preserving the native final corners");
    info.frame = CGRectMake(16, 300, 358, 208);
    addContact.frame = CGRectMake(0, 120, 358, 44);
    size = TGExtraProfileInfoContentSize(scroll, root, CGSizeMake(390, 1188));
    NSCAssert(idRow.frame.origin.y == 420 && addContact.frame.origin.y == 120 &&
              addContact.view.frame.origin.y == 120 + idRow.frame.size.height &&
              info.view.frame.size.height == 208 + idRow.frame.size.height, @"Native relayout cannot accumulate action offsets or section height");
    showProfileInfo = NO;
    size = TGExtraProfileInfoContentSize(scroll, root, CGSizeMake(390, 1100));
    NSCAssert(idRow.hidden && size.height == 1100 && standard.view.frame.origin.y == 532 && !infoMask.layer.mask &&
              addContact.view.frame.origin.y == 120 && info.view.frame.size.height == 208 && items.view.bounds.size.height == 208,
              @"Editing restores host geometry and original corner masks");
    showProfileInfo = YES;
    ASDisplayNode *hours = node(@"TelegramUI.PeerInfoScreenBusinessHoursItemNode", CGRectMake(0, 120, 358, 44));
    ASDisplayNode *address = node(@"TelegramUI.PeerInfoScreenAddressItemNode", CGRectMake(0, 164, 358, 44));
    ASDisplayNode *encryptionKey = node(@"TelegramUI.PeerInfoScreenDisclosureEncryptionKeyItemNode", CGRectMake(0, 208, 358, 44));
    ASDisplayNode *footer = node(@"TelegramUI.PeerInfoScreenCommentItemNode", CGRectMake(0, 252, 358, 24));
    // The native section keeps disappearing views until their fade completes.
    blockUser.frame = CGRectMake(0, 90, 358, 44);
    children(items, @[labeled, hours, address, encryptionKey, footer, blockUser]);
    info.fields = @{@"itemContainerNode": items, @"backgroundNode": infoBackground, @"bottomSeparatorNode": infoBottom,
                    @"itemNodes": @{@1: labeled, @2: hours, @3: address, @4: encryptionKey, @5: footer}};
    info.frame = CGRectMake(16, 300, 358, 276);
    items.frame = CGRectMake(0, 0, 358, 276);
    infoBackground.frame = CGRectMake(0, 0, 358, 252);
    TGExtraProfileInfoContentSize(scroll, root, CGSizeMake(390, 1256));
    NSCAssert(idRow.frame.origin.y == 508 && encryptionKey.view.frame.origin.y == 208 + idRow.frame.size.height &&
              footer.view.frame.origin.y == 252 + idRow.frame.size.height && blockUser.view.frame.origin.y == 90,
              @"Place ID after business details and before a secret-chat key, without relying on contact buttons or fading views");
    ASImageNode *addressMask = [ASImageNode new];
    addressMask.frame = CGRectMake(0, 0, 358, 44);
    addressMask.testImage = cornerImage(NO, YES, UIColor.whiteColor);
    address.fields = @{@"maskNode": addressMask};
    info.fields = @{@"itemContainerNode": items, @"backgroundNode": infoBackground, @"bottomSeparatorNode": infoBottom,
                    @"itemNodes": @{@1: labeled, @2: hours, @3: address, @5: footer}};
    footer.frame = CGRectMake(0, 208, 358, 24);
    info.frame = CGRectMake(16, 300, 358, 232);
    infoBackground.frame = CGRectMake(0, 0, 358, 208);
    TGExtraProfileInfoContentSize(scroll, root, CGSizeMake(390, 1212));
    NSCAssert(idRow.frame.origin.y == 508 && idRow.bottomSeparator.hidden && addressMask.layer.mask != nil &&
              footer.view.frame.origin.y == 208 + idRow.frame.size.height,
              @"A bot footer stays after ID even when no action buttons are present, with corners at the end of the information card");
    info.fields = @{@"itemContainerNode": items, @"backgroundNode": infoBackground, @"bottomSeparatorNode": infoBottom,
                    @"itemNodes": @{@1: labeled, @2: hours, @3: address}};
    info.frame = CGRectMake(16, 300, 358, 208);
    TGExtraProfileInfoContentSize(scroll, root, CGSizeMake(390, 1188));
    NSCAssert(idRow.frame.origin.y == 508 && !idRow.hidden && idRow.bottomSeparator.hidden,
              @"Contacts, own profiles, groups and channels with information but no buttons still show ID after their details");
    showProfileInfo = NO;
    TGExtraProfileInfoContentSize(scroll, root, CGSizeMake(390, 1100));
    NSCAssert(addressMask.layer.mask == nil, @"Restore corners when optional profile rows change");
    showProfileInfo = YES;
    info.fields = @{@"itemContainerNode": items, @"backgroundNode": infoBackground, @"bottomSeparatorNode": infoBottom};
    children(items, @[addContact, blockUser]);
    addContact.frame = CGRectMake(0, 0, 358, 44);
    blockUser.frame = CGRectMake(0, 44, 358, 44);
    items.frame = infoBackground.frame = CGRectMake(0, 0, 358, 88);
    info.frame = CGRectMake(16, 300, 358, 88);
    ASImageNode *actionMask = [ASImageNode new];
    actionMask.frame = CGRectMake(0, 0, 358, 44);
    actionMask.testImage = cornerImage(YES, NO, UIColor.whiteColor);
    addContact.fields = @{@"maskNode": actionMask};
    TGExtraProfileInfoContentSize(scroll, root, CGSizeMake(390, 1100));
    [idRow layoutIfNeeded];
    NSCAssert(idRow.frame.origin.y == 300 && idRow.cornersAtTop && idRow.separator.hidden &&
              actionMask.layer.mask != nil && idRow.corners.layer.contents != nil &&
              addContact.view.frame.origin.y == idRow.frame.size.height,
              @"Profiles containing only action buttons get ID first with the native top corners");
    showProfileInfo = NO;
    TGExtraProfileInfoContentSize(scroll, root, CGSizeMake(390, 1100));
    NSCAssert(actionMask.layer.mask == nil && items.view.frame.size.height == 88, @"Restore first-row masks and clipping after insertion");
    showProfileInfo = YES;
    standard.frame = CGRectMake(16, 444, 358, 200);
    profileScreen.fields = @{@"peerId": @43, @"paneContainerNode": standard};
    UIView *tabs = [[UIView alloc] initWithFrame:CGRectMake(0, 444, 390, 200)];
    [scroll addSubview:tabs];
    UIView *tabButton = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 44, 44)];
    [tabs addSubview:tabButton];
    standard.fields = @{@"headerContainer": tabs};
    standard.view.alpha = 0;
    size = TGExtraProfileInfoContentSize(scroll, root, CGSizeMake(390, 1100));
    NSCAssert(!idRow.hidden && idRow.alpha == 1 && [idRow.value.text isEqualToString:@"43"] && idRow.frame.origin.y == 444,
              @"A profile without public information or media still gets a visible ID row");
    tabs.frame = CGRectMake(0, 444, 390, 200);
    NSCAssert(CGRectGetMinY([tabButton convertRect:tabButton.bounds toView:tabs.superview]) == 444 + idRow.frame.size.height + 24,
              @"Media tabs and their hit targets move together, including after the host updates their frame");
    TGExtraProfileInfoContentSize(scroll, root, CGSizeMake(390, 1100));
    NSCAssert(tabs.bounds.origin.y == -idRow.frame.size.height - 24, @"Tab offsets cannot accumulate");
    profileScreen.fields = @{@"peerId": @43, @"paneContainerNode": standard, @"paneOrigin": @500};
    TGExtraProfileInfoContentSize(scroll, root, CGSizeMake(390, 1100));
    NSCAssert(idRow.frame.origin.y == 518, @"Use the new native layout when the old pane frame is stale");
    standard.view.alpha = 1;
    profileScreen.fields = @{@"peerId": @(-1000000007331), @"infoSection": info};
    TGExtraProfileInfoContentSize(scroll, root, CGSizeMake(390, 1100));
    NSCAssert([idRow.value.text isEqualToString:@"-1000000007331"], @"Keep group/channel IDs distinct from user IDs");
    profileScreen.fields = @{};
    TGExtraProfileInfoContentSize(scroll, root, CGSizeMake(390, 1100));
    NSCAssert(idRow.hidden && standard.view.frame.origin.y == 444 && tabs.bounds.origin.y == 0,
              @"Reused screens restore media tabs and cannot retain another peer's ID");
    puts("PASS UIKit settings and profile ID placement, native corners, repeated layout, editing, VoiceOver and copying");
} }
'''

with tempfile.TemporaryDirectory(prefix='tgextra-settings-menu-') as tmp:
    harness = Path(tmp) / 'menu.m'
    harness.write_text(helpers + mocks + geometry + profile + profile_mocks + tests)
    binary = Path(tmp) / 'menu'
    subprocess.run([
        'xcrun', 'clang', '-target', f'{platform.machine()}-apple-ios15.0-macabi',
        '-isysroot', str(sdk), '-iframework', str(frameworks), '-fobjc-arc',
        '-Werror', '-Wno-deprecated-declarations', '-framework', 'UIKit',
        '-framework', 'Foundation', '-framework', 'QuartzCore', '-framework', 'CoreGraphics',
        str(harness), '-o', str(binary),
    ], check=True)
    subprocess.run([str(binary)], check=True)
