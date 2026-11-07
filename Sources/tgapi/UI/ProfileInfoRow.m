#import "ProfileInfoRow.h"
#import "ProfileBridge.h"
#import "TGExtraLocalization.h"
#import <objc/runtime.h>

void TGExtraShowToast(NSString *text);

static id field(id node, NSString *name) {
    return node ? [TGExtraProfileBridge getStoredField:name fromNode:node] : nil;
}

@interface TGExtraProfileInfoRow : UIControl
@property (nonatomic, strong) UILabel *caption;
@property (nonatomic, strong) UILabel *value;
@property (nonatomic, strong) UIView *separator;
@property (nonatomic, strong) UIView *corners;
@property (nonatomic, strong) CALayer *nativeCorners;
@property (nonatomic, strong) CALayer *originalMask;
@property (nonatomic, strong) CALayer *joinedMask;
@property (nonatomic, copy) NSArray<ASDisplayNode *> *shiftedNodes;
@property (nonatomic, weak) UIView *paneHeader;
@property (nonatomic) CGFloat paneHeaderOffset;
@end

@implementation TGExtraProfileInfoRow
- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.caption = [UILabel new];
        self.value = [UILabel new];
        self.separator = [UIView new];
        self.corners = [UIView new];
        for (UIView *view in @[self.caption, self.value, self.separator, self.corners]) {
            view.userInteractionEnabled = NO;
            [self addSubview:view];
        }
        self.corners.layer.mask = [CALayer layer];
        self.corners.layer.mask.backgroundColor = UIColor.blackColor.CGColor;
        self.isAccessibilityElement = YES;
        self.accessibilityTraits = UIAccessibilityTraitButton;
        [self addTarget:self action:@selector(copyId) forControlEvents:UIControlEventTouchUpInside];
    }
    return self;
}
- (void)copyId {
    UIPasteboard.generalPasteboard.string = self.value.text;
    TGExtraShowToast([TGExtraLocalization localizedStringForKey:@"PROFILE_ID_COPIED"]);
    UIAccessibilityPostNotification(UIAccessibilityAnnouncementNotification,
        [TGExtraLocalization localizedStringForKey:@"PROFILE_ID_COPIED"]);
    UINotificationFeedbackGenerator *feedback = [UINotificationFeedbackGenerator new];
    [feedback notificationOccurred:UINotificationFeedbackTypeSuccess];
}
- (void)setHighlighted:(BOOL)highlighted {
    [super setHighlighted:highlighted];
    self.caption.alpha = self.value.alpha = highlighted ? 0.5 : 1.0;
}
- (void)restore {
    if (self.nativeCorners.mask == self.joinedMask) self.nativeCorners.mask = self.originalMask;
    self.nativeCorners = nil;
    self.originalMask = nil;
    self.joinedMask = nil;
    self.corners.layer.contents = nil;
    if (self.paneHeader) {
        CGRect bounds = self.paneHeader.bounds;
        bounds.origin.y += self.paneHeaderOffset;
        self.paneHeader.bounds = bounds;
    }
    self.paneHeader = nil;
    self.paneHeaderOffset = 0;
    for (ASDisplayNode *node in self.shiftedNodes) TGExtraSetSettingsOffset(node, 0);
    self.shiftedNodes = nil;
    self.hidden = YES;
}
- (void)layoutSubviews {
    [super layoutSubviews];
    BOOL rtl = self.effectiveUserInterfaceLayoutDirection == UIUserInterfaceLayoutDirectionRightToLeft;
    CGFloat width = self.bounds.size.width;
    CGFloat captionHeight = self.caption.font.lineHeight;
    CGFloat valueHeight = self.value.font.lineHeight;
    self.caption.frame = CGRectMake(16, 8, MAX(0, width - 32), captionHeight);
    self.value.frame = CGRectMake(16, 10 + captionHeight, MAX(0, width - 32), valueHeight);
    self.caption.textAlignment = self.value.textAlignment = rtl ? NSTextAlignmentRight : NSTextAlignmentLeft;
    self.separator.frame = CGRectMake(rtl ? 0 : 16, 0, MAX(0, width - 16), 1.0 / UIScreen.mainScreen.scale);
    self.corners.frame = self.bounds;
    self.corners.layer.mask.frame = CGRectMake(0, self.bounds.size.height / 2, width, self.bounds.size.height / 2);
}
@end

static char profileInfoRowKey;

static ASDisplayNode *lastLabeledRow(ASDisplayNode *node) {
    ASDisplayNode *result = nil;
    if ([NSStringFromClass(node.class) containsString:@"PeerInfoScreenLabeledValueItemNode"]) return node;
    for (ASDisplayNode *child in node.subnodes) {
        ASDisplayNode *candidate = lastLabeledRow(child);
        if (candidate && (!result || CGRectGetMaxY(candidate.frame) > CGRectGetMaxY(result.frame))) result = candidate;
    }
    return result;
}

CGSize TGExtraProfileInfoContentSize(UIScrollView *scrollView, ASDisplayNode *scrollNode, CGSize hostSize) {
    TGExtraProfileInfoRow *row = objc_getAssociatedObject(scrollView, &profileInfoRowKey);
    [row restore];
    ASDisplayNode *screen = scrollNode.supernode;
    if (![NSStringFromClass(screen.class) hasSuffix:@".PeerInfoScreenNode"] ||
        ![TGExtraProfileBridge shouldShowProfileInfoFromNode:screen] || hostSize.width <= 0) return hostSize;
    NSNumber *peerId = [TGExtraProfileBridge getPeerIdFromNode:screen];
    if (!peerId || peerId.longLongValue == 0) return hostSize;

    ASDisplayNode *section = [TGExtraProfileBridge getInfoSectionFromNode:screen];
    ASDisplayNode *reference = lastLabeledRow(section);
    ASDisplayNode *pane = field(screen, @"paneContainerNode");
    ASDisplayNode *anchor = section ?: pane;
    if (!anchor) return hostSize;
    CGRect sectionFrame = anchor.frame;
    BOOL joined = reference != nil && sectionFrame.size.height > 0;
    CGFloat insertionY = section ? CGRectGetMaxY(sectionFrame) : CGRectGetMinY(sectionFrame);
    if (!section) {
        NSNumber *paneOrigin = [TGExtraProfileBridge getPaneOriginFromNode:screen contentHeight:hostSize.height];
        if (paneOrigin) insertionY = paneOrigin.doubleValue + 18;
    }
    CGFloat inset = section ? sectionFrame.origin.x : MAX(16, scrollView.safeAreaInsets.left);
    CGFloat width = section ? sectionFrame.size.width : hostSize.width - 2 * inset;
    if (width <= 0) return hostSize;
    if (!row) {
        row = [TGExtraProfileInfoRow new];
        objc_setAssociatedObject(scrollView, &profileInfoRowKey, row, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [scrollView addSubview:row];
    }
    id presentation = field(screen, @"presentationData");
    id theme = field(presentation, @"theme");
    id list = field(theme, @"list");
    UIColor *primary = field(list, @"itemPrimaryTextColor") ?: UIColor.labelColor;
    row.backgroundColor = field(list, @"itemBlocksBackgroundColor") ?: UIColor.secondarySystemGroupedBackgroundColor;
    row.separator.backgroundColor = field(list, @"itemBlocksSeparatorColor") ?: UIColor.separatorColor;
    row.caption.textColor = primary;
    row.value.textColor = primary;
    row.caption.font = [UIFontMetrics.defaultMetrics scaledFontForFont:[UIFont systemFontOfSize:14]];
    row.value.font = [UIFontMetrics.defaultMetrics scaledFontForFont:[UIFont systemFontOfSize:17]];
    row.caption.text = [TGExtraLocalization localizedStringForKey:@"PROFILE_ID"];
    row.value.text = peerId.stringValue;
    row.accessibilityLabel = row.caption.text;
    row.accessibilityValue = row.value.text;
    row.accessibilityHint = [TGExtraLocalization localizedStringForKey:@"PROFILE_ID_COPY_HINT"];
    CGFloat height = MAX(60, 18 + row.caption.font.lineHeight + row.value.font.lineHeight);
    row.separator.hidden = !joined;
    row.layer.cornerRadius = inset > 0 ? 11 : 0;
    row.layer.maskedCorners = joined ? kCALayerMinXMaxYCorner | kCALayerMaxXMaxYCorner : 15;

    // Move the native bottom corner cutouts to the appended row, preserving custom themes.
    ASDisplayNode *mask = field(reference, @"maskNode");
    CALayer *native = mask.layer;
    if (joined && native.contents && CFGetTypeID((__bridge CFTypeRef)native.contents) == CGImageGetTypeID()) {
        row.nativeCorners = native;
        row.originalMask = native.mask;
        row.joinedMask = [CALayer layer];
        row.joinedMask.backgroundColor = UIColor.blackColor.CGColor;
        row.joinedMask.frame = CGRectMake(0, 0, mask.frame.size.width, mask.frame.size.height / 2);
        native.mask = row.joinedMask;
        CALayer *corners = row.corners.layer;
        corners.contents = native.contents;
        corners.contentsScale = native.contentsScale;
        corners.contentsCenter = native.contentsCenter;
        corners.contentsRect = native.contentsRect;
        corners.contentsGravity = native.contentsGravity;
        row.layer.cornerRadius = 0;
    }
    CGFloat offset = height + (joined ? 0 : 24);
    NSMutableArray *shifted = [NSMutableArray array];
    for (ASDisplayNode *node in scrollNode.subnodes) {
        if (node == section || (node != pane && CGRectGetMinY(node.frame) < insertionY)) continue;
        TGExtraSetSettingsOffset(node, offset);
        [shifted addObject:node];
    }
    row.shiftedNodes = shifted;
    // Telegram keeps the media tabs in a separate view above the pane.
    // Shifting its bounds also shifts hit testing and survives the host's later setFrame.
    UIView *paneHeader = field(pane, @"headerContainer");
    if (paneHeader) {
        row.paneHeader = paneHeader;
        row.paneHeaderOffset = offset;
        CGRect bounds = paneHeader.bounds;
        bounds.origin.y -= offset;
        paneHeader.bounds = bounds;
    }
    row.frame = CGRectMake(inset, insertionY, width, height);
    row.alpha = section ? section.alpha : 1;
    row.hidden = section ? section.hidden : NO;
    [row setNeedsLayout];
    return CGSizeMake(hostSize.width, hostSize.height + offset);
}

NSArray *TGExtraProfileInfoAccessibilityElements(UIScrollView *scrollView, NSArray *elements) {
    TGExtraProfileInfoRow *row = objc_getAssociatedObject(scrollView, &profileInfoRowKey);
    if (!row || row.hidden || row.alpha <= 0) return elements;
    NSMutableArray *ordered = [elements mutableCopy] ?: [NSMutableArray array];
    [ordered removeObject:row];
    NSUInteger index = [ordered indexOfObjectPassingTest:^BOOL(id element, NSUInteger idx, BOOL *stop) {
        return CGRectGetMinY([element accessibilityFrame]) > CGRectGetMinY(row.accessibilityFrame);
    }];
    [ordered insertObject:row atIndex:index == NSNotFound ? ordered.count : index];
    return ordered;
}
