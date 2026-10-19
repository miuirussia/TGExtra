#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>

void showUI(void);
BOOL TGExtraIsTelegramSupportLabel(NSString *label);

@interface ASDisplayNode : NSObject
@property (nonatomic, readonly) ASDisplayNode *supernode;
@property (nonatomic, readonly) NSArray *subnodes;
@property (nonatomic, readonly) UIView *view;
@property (nonatomic, readonly) NSString *accessibilityLabel;
@property (nonatomic, readonly, getter=isHidden) BOOL hidden;
@property (nonatomic, readonly) CGFloat alpha;
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

@interface TGExtraSettingsButton : UIButton
@end

@implementation TGExtraSettingsButton
- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        [self setTitle:@"TGExtra" forState:UIControlStateNormal];
        [self setTitleColor:UIColor.labelColor forState:UIControlStateNormal];
        [self setImage:[UIImage systemImageNamed:@"gearshape"] forState:UIControlStateNormal];
        self.contentHorizontalAlignment = UIControlContentHorizontalAlignmentLeading;
        self.contentEdgeInsets = UIEdgeInsetsMake(0.0, 16.0, 0.0, 16.0);
        self.titleEdgeInsets = UIEdgeInsetsMake(0.0, 12.0, 0.0, -12.0);
        self.titleLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
        self.titleLabel.adjustsFontForContentSizeCategory = YES;
        self.backgroundColor = UIColor.secondarySystemGroupedBackgroundColor;
        self.layer.cornerRadius = 11.0;
        self.accessibilityIdentifier = @"TGExtra.Settings";
        [self addTarget:self action:@selector(openMenu) forControlEvents:UIControlEventTouchUpInside];
    }
    return self;
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
    CGFloat height = MAX(44.0, button.titleLabel.font.lineHeight + 24.0);
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
