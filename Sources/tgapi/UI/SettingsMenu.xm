#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#import <math.h>
#import "SettingsNavigation.h"

BOOL TGExtraIsTelegramSupportLabel(NSString *label);
BOOL TGExtraIsMyProfileLabel(NSString *label);

@interface ASDisplayNode : NSObject
@property (nonatomic, readonly) ASDisplayNode *supernode;
@property (nonatomic, readonly) NSArray *subnodes;
@property (nonatomic, readonly) UIView *view;
@property (nonatomic, readonly) NSString *accessibilityLabel;
@property (nonatomic, readonly, getter=isHidden) BOOL hidden;
@property (nonatomic, readonly) CGFloat alpha;
@property (nonatomic) CGRect frame;
@property (nonatomic) CGPoint position;
@property (nonatomic, readonly) UIColor *backgroundColor;
@end

@interface ASImageNode : ASDisplayNode
@property (nonatomic, readonly) UIImage *image;
@end

@interface ASScrollView : UIScrollView
- (ASDisplayNode *)scrollNode;
@end

static ASDisplayNode *TGExtraFindSettingsRow(ASDisplayNode *node, BOOL (^matches)(NSString *)) {
    if (node.hidden || node.alpha <= 0.0) return nil;
    if ([NSStringFromClass(node.class) containsString:@"AccessibilityAreaNode"] &&
        [NSStringFromClass(node.supernode.class) containsString:@"PeerInfoScreenDisclosureItemNode"] &&
        matches(node.accessibilityLabel)) {
        return node.supernode;
    }
    for (ASDisplayNode *child in node.subnodes) {
        ASDisplayNode *row = TGExtraFindSettingsRow(child, matches);
        if (row) return row;
    }
    return nil;
}

static ASDisplayNode *TGExtraSettingsSection(ASDisplayNode *row, ASDisplayNode *scrollNode) {
    ASDisplayNode *section = row;
    while (section && section.supernode != scrollNode) section = section.supernode;
    return [NSStringFromClass(section.class) hasSuffix:@".PeerInfoScreenItemSectionContainerNode"] ? section : nil;
}

// Keep the host's layout coordinates intact while reserving space for our row.
@interface TGExtraSettingsOffset : NSObject
@property (nonatomic) CGFloat offset;
@property (nonatomic) BOOL accessingGeometry;
@end
@implementation TGExtraSettingsOffset
@end

static char TGExtraSettingsOffsetKey;

static void TGExtraSetSettingsOffset(ASDisplayNode *node, CGFloat offset) {
    CGRect frame = node.frame;
    TGExtraSettingsOffset *state = objc_getAssociatedObject(node, &TGExtraSettingsOffsetKey);
    if (!state && offset == 0.0) return;
    if (!state) {
        state = [TGExtraSettingsOffset new];
        objc_setAssociatedObject(node, &TGExtraSettingsOffsetKey, state, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    state.offset = offset;
    node.frame = frame;
    if (offset == 0.0) objc_setAssociatedObject(node, &TGExtraSettingsOffsetKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static UIUserInterfaceStyle TGExtraSettingsStyleForBackground(UIColor *background, UITraitCollection *traits) {
    UIColor *color = [background resolvedColorWithTraitCollection:traits];
    CGFloat red, green, blue, alpha;
    if (![color getRed:&red green:&green blue:&blue alpha:&alpha] || alpha < 1.0) {
        return traits.userInterfaceStyle;
    }
    CGFloat channels[] = {red, green, blue};
    for (NSUInteger i = 0; i < 3; i++) {
        CGFloat value = MAX(0.0, MIN(1.0, channels[i]));
        channels[i] = value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4);
    }
    CGFloat luminance = 0.2126 * channels[0] + 0.7152 * channels[1] + 0.0722 * channels[2];
    return (1.05 / (luminance + 0.05) > (luminance + 0.05) / 0.05)
        ? UIUserInterfaceStyleDark : UIUserInterfaceStyleLight;
}

@interface TGExtraSettingsButton : UIButton
@property (nonatomic, strong) UIView *iconTile;
@property (nonatomic, strong) CAGradientLayer *iconGradient;
@property (nonatomic, strong) UIImageView *disclosureView;
@property (nonatomic) CGRect referenceTitleFrame;
@property (nonatomic) CGRect referenceIconFrame;
@property (nonatomic) CGRect referenceArrowFrame;
@property (nonatomic, copy) NSArray<ASDisplayNode *> *shiftedNodes;
- (void)matchSupportRow:(ASDisplayNode *)row;
@end

@implementation TGExtraSettingsButton
- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        [self setTitle:@"TGExtra" forState:UIControlStateNormal];
        [self setTitleColor:UIColor.labelColor forState:UIControlStateNormal];
        UIImageSymbolConfiguration *symbol = [UIImageSymbolConfiguration configurationWithPointSize:22.0 weight:UIImageSymbolWeightRegular];
        [self setImage:[UIImage systemImageNamed:@"gearshape.fill" withConfiguration:symbol] forState:UIControlStateNormal];
        self.tintColor = UIColor.whiteColor;
        self.contentHorizontalAlignment = UIControlContentHorizontalAlignmentLeading;
        self.titleLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
        self.titleLabel.adjustsFontForContentSizeCategory = YES;
        self.iconTile = [[UIView alloc] initWithFrame:CGRectZero];
        self.iconTile.userInteractionEnabled = NO;
        self.iconTile.layer.cornerRadius = 7.0;
        self.iconTile.layer.masksToBounds = YES;
        self.iconGradient = [CAGradientLayer layer];
        self.iconGradient.colors = @[(id)UIColor.systemTealColor.CGColor, (id)UIColor.systemBlueColor.CGColor];
        [self.iconTile.layer addSublayer:self.iconGradient];
        [self insertSubview:self.iconTile belowSubview:self.imageView];
        UIImage *arrow = [UIImage imageNamed:@"Item List/DisclosureArrow"];
        if (!arrow) {
            UIImageSymbolConfiguration *arrowSymbol = [UIImageSymbolConfiguration configurationWithPointSize:13.0 weight:UIImageSymbolWeightSemibold];
            arrow = [UIImage systemImageNamed:@"chevron.right" withConfiguration:arrowSymbol];
        }
        self.disclosureView = [[UIImageView alloc] initWithImage:[arrow imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate]];
        self.disclosureView.contentMode = UIViewContentModeCenter;
        self.disclosureView.tintColor = UIColor.tertiaryLabelColor;
        [self addSubview:self.disclosureView];
        self.backgroundColor = UIColor.secondarySystemGroupedBackgroundColor;
        self.layer.cornerRadius = 11.0;
        self.layer.cornerCurve = kCACornerCurveContinuous;
        self.clipsToBounds = YES;
        self.isAccessibilityElement = YES;
        self.accessibilityLabel = @"TGExtra";
        self.accessibilityIdentifier = @"TGExtra.Settings";
        [self addTarget:self action:@selector(openMenu) forControlEvents:UIControlEventTouchUpInside];
    }
    return self;
}
- (void)matchSupportRow:(ASDisplayNode *)row {
    CGFloat width = row.view.bounds.size.width;
    CGFloat height = row.view.bounds.size.height;
    self.referenceTitleFrame = CGRectMake(61.0, 0.0, 0.0, 0.0);
    self.referenceIconFrame = CGRectMake(16.0, (height - 30.0) / 2.0, 30.0, 30.0);
    self.referenceArrowFrame = CGRectMake(width - 31.0, (height - 24.0) / 2.0, 24.0, 24.0);
    for (ASDisplayNode *node in row.subnodes) {
        CGRect frame = node.frame;
        if ([NSStringFromClass(node.class) containsString:@"ImmediateTextNode"] &&
            frame.size.width > 0.0 && frame.size.height > 0.0 && frame.origin.x < width / 2.0) {
            self.referenceTitleFrame = frame;
            UIFont *baseFont = [UIFont systemFontOfSize:17.0];
            self.titleLabel.font = [UIFont systemFontOfSize:ceil(17.0 * frame.size.height / baseFont.lineHeight)];
        }
        if ([node respondsToSelector:@selector(image)]) {
            UIImage *image = [(ASImageNode *)node image];
            if (!image || frame.size.width <= 0.0 || frame.size.height <= 0.0) continue;
            if (frame.origin.x > width / 2.0 && frame.size.width <= 40.0 && frame.size.height <= 40.0) {
                self.referenceArrowFrame = frame;
                self.disclosureView.image = [image imageWithRenderingMode:UIImageRenderingModeAlwaysOriginal];
            } else if (frame.size.width <= 40.0 && frame.size.height <= 40.0 && frame.origin.x < width / 2.0) {
                self.referenceIconFrame = frame;
            }
        }
    }
    self.backgroundColor = UIColor.secondarySystemGroupedBackgroundColor;
    for (ASDisplayNode *node in row.supernode.supernode.subnodes) {
        if (node.backgroundColor && node.frame.size.height > 1.0 && node.alpha > 0.0) {
            self.backgroundColor = node.backgroundColor;
            break;
        }
    }
    self.overrideUserInterfaceStyle = TGExtraSettingsStyleForBackground(self.backgroundColor, row.view.traitCollection);
    if (@available(iOS 26.0, *)) {
        self.layer.cornerRadius = 26.0;
    }
    [self setNeedsLayout];
}
- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat height = self.bounds.size.height;
    self.iconTile.frame = self.referenceIconFrame;
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    self.iconGradient.frame = self.iconTile.bounds;
    [CATransaction commit];
    self.imageView.frame = CGRectInset(self.iconTile.frame, 4.0, 4.0);
    self.imageView.contentMode = UIViewContentModeScaleAspectFit;
    self.disclosureView.frame = self.referenceArrowFrame;
    CGFloat titleX = self.referenceTitleFrame.origin.x;
    CGFloat titleHeight = MAX(self.referenceTitleFrame.size.height, self.titleLabel.font.lineHeight);
    self.titleLabel.frame = CGRectMake(titleX, floor((height - titleHeight) / 2.0),
                                      MAX(0.0, CGRectGetMinX(self.disclosureView.frame) - 16.0 - titleX), titleHeight);
}
- (void)setHighlighted:(BOOL)highlighted {
    [super setHighlighted:highlighted];
    self.alpha = highlighted ? 0.65 : 1.0;
}
- (void)openMenu {
    TGExtraShowSettings();
}
@end

static char TGExtraSettingsButtonKey;

static CGSize TGExtraSettingsContentSize(ASScrollView *scrollView, CGSize hostSize) {
    TGExtraSettingsButton *button = objc_getAssociatedObject(scrollView, &TGExtraSettingsButtonKey);
    for (ASDisplayNode *node in button.shiftedNodes) TGExtraSetSettingsOffset(node, 0.0);
    button.shiftedNodes = nil;
    ASDisplayNode *scrollNode = [scrollView scrollNode];
    ASDisplayNode *screenNode = scrollNode.supernode;
    ASDisplayNode *supportRow = nil;
    ASDisplayNode *profileRow = nil;
    if ([NSStringFromClass(screenNode.class) hasSuffix:@".PeerInfoScreenNode"]) {
        supportRow = TGExtraFindSettingsRow(scrollNode, ^BOOL(NSString *label) { return TGExtraIsTelegramSupportLabel(label); });
        profileRow = TGExtraFindSettingsRow(scrollNode, ^BOOL(NSString *label) { return TGExtraIsMyProfileLabel(label); });
    }
    ASDisplayNode *anchorSection = TGExtraSettingsSection(profileRow, scrollNode);
    if (!supportRow || !anchorSection || hostSize.width <= 0.0 || hostSize.height <= 0.0) {
        button.hidden = YES;
        return hostSize;
    }
    for (ASDisplayNode *section in scrollNode.subnodes) {
        if (section.hidden || section.alpha <= 0.0 || section.frame.size.height <= 0.0 ||
            CGRectGetMinY(section.frame) < CGRectGetMaxY(anchorSection.frame)) continue;
        ASDisplayNode *swiftgramRow = TGExtraFindSettingsRow(section, ^BOOL(NSString *label) {
            return [label isEqualToString:@"Swiftgram"] || [label isEqualToString:@"Swiftgram Pro"];
        });
        if (TGExtraSettingsSection(swiftgramRow, scrollNode) == section) anchorSection = section;
    }
    if (!button) {
        button = [[TGExtraSettingsButton alloc] initWithFrame:CGRectZero];
        objc_setAssociatedObject(scrollView, &TGExtraSettingsButtonKey, button, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [scrollView addSubview:button];
    }
    CGRect rowFrame = [supportRow.view convertRect:supportRow.view.bounds toView:scrollView];
    [button matchSupportRow:supportRow];
    CGFloat height = MAX(44.0, rowFrame.size.height);
    CGFloat anchorBottom = CGRectGetMaxY(anchorSection.frame);
    CGFloat spacing = 24.0;
    CGFloat offset = height + spacing;
    NSMutableArray<ASDisplayNode *> *shiftedNodes = [NSMutableArray array];
    for (ASDisplayNode *node in scrollNode.subnodes) {
        if (CGRectGetMinY(node.frame) < anchorBottom) continue;
        TGExtraSetSettingsOffset(node, offset);
        [shiftedNodes addObject:node];
    }
    button.shiftedNodes = shiftedNodes;
    button.frame = CGRectMake(rowFrame.origin.x, anchorBottom + spacing, rowFrame.size.width, height);
    button.hidden = NO;
    return CGSizeMake(hostSize.width, hostSize.height + offset);
}

static NSArray *TGExtraSettingsAccessibilityElements(ASScrollView *scrollView, NSArray *elements) {
    TGExtraSettingsButton *button = objc_getAssociatedObject(scrollView, &TGExtraSettingsButtonKey);
    if (button && !button.hidden) {
        NSMutableArray *ordered = [elements mutableCopy] ?: [NSMutableArray array];
        [ordered removeObject:button];
        NSUInteger index = [ordered indexOfObjectPassingTest:^BOOL(id element, NSUInteger idx, BOOL *stop) {
            return CGRectGetMinY([element accessibilityFrame]) > CGRectGetMinY(button.accessibilityFrame);
        }];
        [ordered insertObject:button atIndex:index == NSNotFound ? ordered.count : index];
        return ordered;
    }
    return elements;
}

%group TGExtraSettingsMenu
%hook ASDisplayNode
- (CGRect)frame {
    TGExtraSettingsOffset *state = objc_getAssociatedObject(self, &TGExtraSettingsOffsetKey);
    if (!state || state.accessingGeometry) return %orig;
    state.accessingGeometry = YES;
    CGRect frame = %orig;
    state.accessingGeometry = NO;
    frame.origin.y -= state.offset;
    return frame;
}
- (void)setFrame:(CGRect)frame {
    TGExtraSettingsOffset *state = objc_getAssociatedObject(self, &TGExtraSettingsOffsetKey);
    if (!state || state.accessingGeometry) {
        %orig(frame);
        return;
    }
    frame.origin.y += state.offset;
    state.accessingGeometry = YES;
    %orig(frame);
    state.accessingGeometry = NO;
}
- (CGPoint)position {
    TGExtraSettingsOffset *state = objc_getAssociatedObject(self, &TGExtraSettingsOffsetKey);
    if (!state || state.accessingGeometry) return %orig;
    state.accessingGeometry = YES;
    CGPoint position = %orig;
    state.accessingGeometry = NO;
    position.y -= state.offset;
    return position;
}
- (void)setPosition:(CGPoint)position {
    TGExtraSettingsOffset *state = objc_getAssociatedObject(self, &TGExtraSettingsOffsetKey);
    if (!state || state.accessingGeometry) {
        %orig(position);
        return;
    }
    position.y += state.offset;
    state.accessingGeometry = YES;
    %orig(position);
    state.accessingGeometry = NO;
}
%end

%hook ASScrollView
- (void)setContentSize:(CGSize)size {
    %orig(TGExtraSettingsContentSize(self, size));
}
- (NSArray *)accessibilityElements {
    NSArray *elements = %orig;
    return TGExtraSettingsAccessibilityElements(self, elements);
}
%end
%end

%ctor {
    Class scrollView = objc_getClass("ASScrollView");
    if (scrollView && class_getInstanceMethod(scrollView, @selector(scrollNode))) {
        %init(TGExtraSettingsMenu, ASScrollView = scrollView, ASDisplayNode = objc_getClass("ASDisplayNode"));
    }
}
