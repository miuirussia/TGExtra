#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#import <math.h>

void showUI(void);
BOOL TGExtraIsTelegramSupportLabel(NSString *label);

@interface ASDisplayNode : NSObject
@property (nonatomic, readonly) ASDisplayNode *supernode;
@property (nonatomic, readonly) NSArray *subnodes;
@property (nonatomic, readonly) UIView *view;
@property (nonatomic, readonly) NSString *accessibilityLabel;
@property (nonatomic, readonly, getter=isHidden) BOOL hidden;
@property (nonatomic, readonly) CGFloat alpha;
@property (nonatomic, readonly) CGRect frame;
@property (nonatomic, readonly) UIColor *backgroundColor;
@end

@interface ASImageNode : ASDisplayNode
@property (nonatomic, readonly) UIImage *image;
@end

@interface ASScrollView : UIScrollView
- (ASDisplayNode *)scrollNode;
@end

// Telegram release-13.0.0, f1dd7a2: PeerInfoScreenNode writes contentSize
// after laying out its settings sections. ASScrollView.scrollNode and all the
// node properties below are Objective-C APIs inherited from AsyncDisplayKit.
// No Swift method, stored property or closure needs to be patched.
static ASDisplayNode *TGExtraFindSupportRow(ASDisplayNode *node) {
    if (node.hidden || node.alpha <= 0.0) return nil;
    if ([NSStringFromClass(node.class) containsString:@"AccessibilityAreaNode"] &&
        [NSStringFromClass(node.supernode.class) containsString:@"PeerInfoScreenDisclosureItemNode"] &&
        TGExtraIsTelegramSupportLabel(node.accessibilityLabel)) {
        return node.supernode;
    }
    for (ASDisplayNode *child in node.subnodes) {
        ASDisplayNode *row = TGExtraFindSupportRow(child);
        if (row) return row;
    }
    return nil;
}

static UIUserInterfaceStyle TGExtraSettingsStyleForBackground(UIColor *background, UITraitCollection *traits) {
    UIColor *color = [background resolvedColorWithTraitCollection:traits];
    CGFloat red, green, blue, alpha;
    if (![color getRed:&red green:&green blue:&blue alpha:&alpha] || alpha < 1.0) {
        return traits.userInterfaceStyle;
    }
    // Choose the foreground with greater contrast against Telegram's surface,
    // which may use a night/custom theme while iOS itself is in light mode.
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
        self.disclosureView = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"chevron.right"]];
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
    self.referenceArrowFrame = CGRectMake(width - 22.0, (height - 13.0) / 2.0, 7.0, 13.0);
    // Read public ASDisplayNode geometry, including layer-backed icons. Swift
    // text properties are not exposed to Objective-C and are left untouched.
    for (ASDisplayNode *node in row.subnodes) {
        CGRect frame = node.frame;
        if ([NSStringFromClass(node.class) containsString:@"ImmediateTextNode"] &&
            frame.size.width > 0.0 && frame.size.height > 0.0 && frame.origin.x < width / 2.0) {
            self.referenceTitleFrame = frame;
            UIFont *baseFont = [UIFont systemFontOfSize:17.0];
            // Telegram floors its single-line Core Text height.
            self.titleLabel.font = [UIFont systemFontOfSize:ceil(17.0 * frame.size.height / baseFont.lineHeight)];
        }
        if ([node respondsToSelector:@selector(image)]) {
            UIImage *image = [(ASImageNode *)node image];
            if (!image || frame.size.width <= 0.0 || frame.size.height <= 0.0) continue;
            if (frame.origin.x > width / 2.0 && frame.size.width < 20.0) {
                self.referenceArrowFrame = frame;
                self.disclosureView.image = image;
            } else if (frame.size.width <= 40.0 && frame.size.height <= 40.0 && frame.origin.x < width / 2.0) {
                self.referenceIconFrame = frame;
            }
        }
    }
    // The section background is layer-backed too. Use its host theme color.
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
    showUI();
}
@end

static char TGExtraSettingsButtonKey;

static CGSize TGExtraSettingsContentSize(ASScrollView *scrollView, CGSize hostSize) {
    TGExtraSettingsButton *button = objc_getAssociatedObject(scrollView, &TGExtraSettingsButtonKey);
    ASDisplayNode *scrollNode = [scrollView scrollNode];
    ASDisplayNode *screenNode = scrollNode.supernode;
    ASDisplayNode *supportRow = nil;
    if ([NSStringFromClass(screenNode.class) hasSuffix:@".PeerInfoScreenNode"]) {
        supportRow = TGExtraFindSupportRow(scrollNode);
    }
    if (!supportRow || hostSize.width <= 0.0 || hostSize.height <= 0.0) {
        button.hidden = YES;
        return hostSize;
    }
    if (!button) {
        button = [[TGExtraSettingsButton alloc] initWithFrame:CGRectZero];
        objc_setAssociatedObject(scrollView, &TGExtraSettingsButtonKey, button, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [scrollView addSubview:button];
    }
    // Match the real section's insets, including the narrower layout on iPad.
    CGRect rowFrame = [supportRow.view convertRect:supportRow.view.bounds toView:scrollView];
    [button matchSupportRow:supportRow];
    CGFloat height = MAX(44.0, rowFrame.size.height);
    button.frame = CGRectMake(rowFrame.origin.x, hostSize.height + 8.0, rowFrame.size.width, height);
    button.hidden = NO;
    // Always extend the size supplied by Telegram, never our previous result.
    // Repeated layouts therefore cannot keep growing the scrollable area.
    return CGSizeMake(hostSize.width, hostSize.height + height + 24.0);
}

%group TGExtraSettingsMenu
%hook ASScrollView
- (void)setContentSize:(CGSize)size {
    %orig(TGExtraSettingsContentSize(self, size));
}
- (NSArray *)accessibilityElements {
    NSArray *elements = %orig;
    TGExtraSettingsButton *button = objc_getAssociatedObject(self, &TGExtraSettingsButtonKey);
    if (button && !button.hidden) return [(elements ?: @[]) arrayByAddingObject:button];
    return elements;
}
%end
%end

%ctor {
    Class scrollView = objc_getClass("ASScrollView");
    if (scrollView && class_getInstanceMethod(scrollView, @selector(scrollNode))) {
        %init(TGExtraSettingsMenu, ASScrollView = scrollView);
    }
}
