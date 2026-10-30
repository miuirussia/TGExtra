#import "HostDisplayNode.h"
#import "SettingsMenuButton.h"
#import <objc/runtime.h>

BOOL TGExtraIsTelegramSupportLabel(NSString *label);
BOOL TGExtraIsMyProfileLabel(NSString *label);

@interface ASScrollView : UIScrollView
- (ASDisplayNode *)scrollNode;
@end

static void TGExtraCollectSettingsRows(ASDisplayNode *node, NSMutableArray<ASDisplayNode *> *rows) {
    if (node.hidden || node.alpha <= 0.0) return;
    if ([NSStringFromClass(node.class) containsString:@"AccessibilityAreaNode"] &&
        [NSStringFromClass(node.supernode.class) containsString:@"PeerInfoScreenDisclosureItemNode"]) {
        [rows addObject:node];
        return;
    }
    for (ASDisplayNode *child in node.subnodes) TGExtraCollectSettingsRows(child, rows);
}

static ASDisplayNode *TGExtraSettingsSection(ASDisplayNode *row, ASDisplayNode *scrollNode) {
    ASDisplayNode *section = row;
    while (section && section.supernode != scrollNode) section = section.supernode;
    return [NSStringFromClass(section.class) hasSuffix:@".PeerInfoScreenItemSectionContainerNode"] ? section : nil;
}

static ASDisplayNode *TGExtraSettingsAnchor(ASDisplayNode *scrollNode, ASDisplayNode **referenceRow, BOOL *joined) {
    if (![NSStringFromClass(scrollNode.supernode.class) hasSuffix:@".PeerInfoScreenNode"]) return nil;
    NSMutableArray<ASDisplayNode *> *rows = [NSMutableArray array];
    TGExtraCollectSettingsRows(scrollNode, rows);
    ASDisplayNode *supportRow = nil, *profileRow = nil;
    for (ASDisplayNode *area in rows) {
        if (!supportRow && TGExtraIsTelegramSupportLabel(area.accessibilityLabel)) supportRow = area.supernode;
        if (!profileRow && TGExtraIsMyProfileLabel(area.accessibilityLabel)) profileRow = area.supernode;
    }
    ASDisplayNode *profileSection = TGExtraSettingsSection(profileRow, scrollNode);
    if (!supportRow || !profileSection) return nil;

    ASDisplayNode *anchor = profileSection;
    for (ASDisplayNode *area in rows) {
        NSString *label = area.accessibilityLabel;
        if (![label isEqualToString:@"Swiftgram"] && ![label isEqualToString:@"Swiftgram Pro"]) continue;
        ASDisplayNode *section = TGExtraSettingsSection(area.supernode, scrollNode);
        if (section.frame.size.height > 0.0 && CGRectGetMinY(section.frame) >= CGRectGetMaxY(anchor.frame)) anchor = section;
    }
    *joined = anchor != profileSection;
    *referenceRow = supportRow;
    if (*joined) {
        CGFloat lastBottom = -CGFLOAT_MAX;
        for (ASDisplayNode *area in rows) {
            ASDisplayNode *row = area.supernode;
            if (TGExtraSettingsSection(row, scrollNode) != anchor) continue;
            CGRect frame = [row.view convertRect:row.view.bounds toView:anchor.view];
            if (CGRectGetMaxY(frame) > lastBottom) {
                lastBottom = CGRectGetMaxY(frame);
                *referenceRow = row;
            }
        }
    }
    return anchor;
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

static char TGExtraSettingsButtonKey;
static char TGExtraSettingsShiftedNodesKey;

static CGSize TGExtraSettingsContentSize(ASScrollView *scrollView, CGSize hostSize) {
    TGExtraSettingsButton *button = objc_getAssociatedObject(scrollView, &TGExtraSettingsButtonKey);
    [button restoreJoinedRow];
    NSArray *shiftedNodes = objc_getAssociatedObject(scrollView, &TGExtraSettingsShiftedNodesKey);
    for (ASDisplayNode *node in shiftedNodes) TGExtraSetSettingsOffset(node, 0.0);
    objc_setAssociatedObject(scrollView, &TGExtraSettingsShiftedNodesKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    ASDisplayNode *scrollNode = [scrollView scrollNode];
    ASDisplayNode *referenceRow = nil;
    BOOL joinsSwiftgram = NO;
    ASDisplayNode *anchorSection = TGExtraSettingsAnchor(scrollNode, &referenceRow, &joinsSwiftgram);
    if (!anchorSection || hostSize.width <= 0.0 || hostSize.height <= 0.0) {
        button.hidden = YES;
        return hostSize;
    }
    if (!button) {
        button = [[TGExtraSettingsButton alloc] initWithFrame:CGRectZero];
        objc_setAssociatedObject(scrollView, &TGExtraSettingsButtonKey, button, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [scrollView addSubview:button];
    }
    CGRect rowFrame = [referenceRow.view convertRect:referenceRow.view.bounds toView:scrollView];
    [button matchRow:referenceRow joined:joinsSwiftgram];
    CGFloat height = MAX(44.0, rowFrame.size.height);
    CGFloat anchorBottom = CGRectGetMaxY(anchorSection.frame);
    CGFloat spacing = joinsSwiftgram ? 0.0 : 24.0;
    CGFloat offset = height + spacing;
    NSMutableArray<ASDisplayNode *> *displacedNodes = [NSMutableArray array];
    for (ASDisplayNode *node in scrollNode.subnodes) {
        if (CGRectGetMinY(node.frame) < anchorBottom) continue;
        TGExtraSetSettingsOffset(node, offset);
        [displacedNodes addObject:node];
    }
    objc_setAssociatedObject(scrollView, &TGExtraSettingsShiftedNodesKey, displacedNodes, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
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
