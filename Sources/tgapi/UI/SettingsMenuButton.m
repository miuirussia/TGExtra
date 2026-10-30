#import "SettingsMenuButton.h"
#import "HostDisplayNode.h"
#import "SettingsNavigation.h"
#import <QuartzCore/QuartzCore.h>
#import <math.h>

@interface ASImageNode : ASDisplayNode
@property (nonatomic, readonly) UIImage *image;
@end

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

@interface TGExtraSettingsButton ()
@property (nonatomic, strong) UIView *iconTile;
@property (nonatomic, strong) CAGradientLayer *iconGradient;
@property (nonatomic, strong) UIImageView *disclosureView;
@property (nonatomic, strong) UIView *topSeparator;
@property (nonatomic, strong) ASDisplayNode *joinedMaskNode;
@property (nonatomic, strong) CALayer *joinedMask;
@property (nonatomic, strong) CALayer *originalMask;
@property (nonatomic) CGRect referenceTitleFrame;
@property (nonatomic) CGRect referenceIconFrame;
@property (nonatomic) CGRect referenceArrowFrame;
- (void)joinSwiftgramRow:(ASDisplayNode *)row;
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
        self.topSeparator = [UIView new];
        self.topSeparator.userInteractionEnabled = NO;
        self.topSeparator.hidden = YES;
        [self addSubview:self.topSeparator];
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
- (void)matchRow:(ASDisplayNode *)row joined:(BOOL)joined {
    self.topSeparator.hidden = YES;
    self.layer.maskedCorners = kCALayerMinXMinYCorner | kCALayerMaxXMinYCorner | kCALayerMinXMaxYCorner | kCALayerMaxXMaxYCorner;
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
    if (joined) [self joinSwiftgramRow:row];
    [self setNeedsLayout];
}
- (void)restoreJoinedRow {
    if (self.joinedMaskNode.layer.mask == self.joinedMask) {
        self.joinedMaskNode.layer.mask = self.originalMask;
    }
    self.joinedMaskNode = nil;
    self.joinedMask = nil;
    self.originalMask = nil;
}
- (void)joinSwiftgramRow:(ASDisplayNode *)row {
    self.layer.maskedCorners = kCALayerMinXMaxYCorner | kCALayerMaxXMaxYCorner;
    self.topSeparator.hidden = NO;
    self.topSeparator.backgroundColor = UIColor.separatorColor;
    for (ASDisplayNode *node in row.subnodes) {
        if (node.frame.size.height <= 1.0 && node.backgroundColor) {
            self.topSeparator.backgroundColor = node.backgroundColor;
        }
        if (![node respondsToSelector:@selector(image)] || ![(ASImageNode *)node image] ||
            node.frame.size.width < row.frame.size.width - 1.0 ||
            node.frame.size.height < row.frame.size.height - 1.0) continue;
        // Preserve the upper corners of a single-row Swiftgram section and
        // remove its lower corner cutouts where TGExtra continues the group.
        self.joinedMaskNode = node;
        self.originalMask = node.layer.mask;
        CALayer *mask = [CALayer layer];
        CGRect bounds = node.layer.bounds;
        mask.frame = CGRectMake(bounds.origin.x, bounds.origin.y, bounds.size.width, bounds.size.height / 2.0);
        mask.backgroundColor = UIColor.blackColor.CGColor;
        self.joinedMask = mask;
        node.layer.mask = mask;
        break;
    }
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
    self.topSeparator.frame = CGRectMake(titleX, 0.0, MAX(0.0, self.bounds.size.width - titleX - 16.0), 1.0 / UIScreen.mainScreen.scale);
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

