#import "../Compatibility.h"
#import "MessageBadges.h"
#import "../Headers.h"
#import "../PaidMedia.h"
static NSHashTable *activeMessageNodes = nil;

static void trackTGExtraMessageNode(ASDisplayNode *node) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        activeMessageNodes = [NSHashTable weakObjectsHashTable];
    });
    @synchronized(activeMessageNodes) {
        [activeMessageNodes addObject:node];
    }
}

static NSHashTable *pendingMessageNodes = nil;
static BOOL messageBadgeUpdateScheduled = NO;

void TGExtraScheduleMessageBadgeUpdate(ASDisplayNode *node) {
    if (!NSThread.isMainThread) {
        dispatch_async(dispatch_get_main_queue(), ^{ TGExtraScheduleMessageBadgeUpdate(node); });
        return;
    }
    trackTGExtraMessageNode(node);
    if (!pendingMessageNodes) pendingMessageNodes = [NSHashTable weakObjectsHashTable];
    [pendingMessageNodes addObject:node];
    if (messageBadgeUpdateScheduled) return;
    messageBadgeUpdateScheduled = YES;
    dispatch_async(dispatch_get_main_queue(), ^{
        NSArray *nodes = pendingMessageNodes.allObjects;
        [pendingMessageNodes removeAllObjects];
        messageBadgeUpdateScheduled = NO;
        for (ASDisplayNode *current in nodes) {
            NSDictionary *state = [TLParser messageStateFromNode:current observe:YES];
            TGExtraUpdateMessageStatusBadge(current, state[@"id"], state[@"peer"], state[@"account"], state[@"namespace"]);
            TGExtraUpdateEditBadge(current, state[@"id"], state[@"peer"], state[@"account"], state[@"namespace"]);
        }
    });
}

@interface UIView (TGExtraMessageNode)
- (ASDisplayNode *)asyncdisplaykit_node;
@end

ASDisplayNode *TGExtraMessageNodeForView(UIView *view) {
    if (![view respondsToSelector:@selector(asyncdisplaykit_node)]) return nil;
    ASDisplayNode *node = [view asyncdisplaykit_node];
    NSString *name = NSStringFromClass([node class]);
    return [name containsString:@"ChatMessage"] && [name containsString:@"ItemNode"] ? node : nil;
}

%group TGExtraMessageViewLayout
%hook _ASDisplayView
- (void)layoutSubviews {
    %orig;
    if ([(UIView *)self respondsToSelector:@selector(asyncdisplaykit_node)]) {
        TGExtraUpdatePaidMediaSaveButton([(UIView *)self asyncdisplaykit_node]);
    }
    ASDisplayNode *node = TGExtraMessageNodeForView((UIView *)self);
    if (node) TGExtraScheduleMessageBadgeUpdate(node);
}
%end
%end

%group TGExtraMessageViewWindow
%hook _ASDisplayView
- (void)didMoveToWindow {
    %orig;
    if ([(UIView *)self respondsToSelector:@selector(asyncdisplaykit_node)]) {
        TGExtraUpdatePaidMediaSaveButton([(UIView *)self asyncdisplaykit_node]);
    }
    ASDisplayNode *node = TGExtraMessageNodeForView((UIView *)self);
    if (node) TGExtraScheduleMessageBadgeUpdate(node);
}
%end
%end

@interface TGExtraAntiRevokeUpdater : NSObject
@end
@implementation TGExtraAntiRevokeUpdater
+ (instancetype)shared {
    static id instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [self new];
        [[NSNotificationCenter defaultCenter] addObserver:instance selector:@selector(handleMessagesChanged:) name:@"TGExtraMessageDeletedRealtime" object:nil];
        [[NSNotificationCenter defaultCenter] addObserver:instance selector:@selector(handleMessagesChanged:) name:@"TGExtraMessageEditedRealtime" object:nil];
        [[NSNotificationCenter defaultCenter] addObserver:instance selector:@selector(handleMessageDataCleared:) name:@"TGExtraMessageDataCleared" object:nil];
    });
    return instance;
}
- (void)handleMessageDataCleared:(NSNotification *)note {
    NSHashTable *nodesCopy = nil;
    @synchronized(activeMessageNodes) {
        nodesCopy = [activeMessageNodes copy];
    }
    for (ASDisplayNode *node in nodesCopy) {
        for (UIView *view in node.view.subviews) {
            if (view.tag == 8898) view.hidden = YES;
            if (view.tag == 8899) TGExtraClearEditBadgeBinding((UIButton *)view);
        }
    }
}
- (void)handleMessagesChanged:(NSNotification *)note {
    NSArray *deletedIds = note.userInfo[@"ids"];
    NSNumber *maxId = note.userInfo[@"maxId"];
    if (deletedIds.count == 0 && !maxId) return;

    NSHashTable *nodesCopy = nil;
    @synchronized(activeMessageNodes) {
        nodesCopy = [activeMessageNodes copy];
    }

    for (ASDisplayNode *node in nodesCopy) {
        NSDictionary *state = [TLParser messageStateFromNode:node observe:NO];
        NSNumber *msgId = state[@"id"];
        if (!msgId || (![deletedIds containsObject:msgId] && !(maxId && msgId.intValue > 0 && msgId.intValue <= maxId.intValue))) continue;
        NSString *account = note.userInfo[@"account"];
        if (account && ![account isEqualToString:state[@"account"]]) continue;
        NSNumber *changedPeer = note.userInfo[@"peer"];
        NSNumber *messageNamespace = note.userInfo[@"namespace"];
        if (messageNamespace && ![messageNamespace isEqual:state[@"namespace"]]) continue;
        NSNumber *nodePeer = state[@"peer"];
        if (changedPeer && changedPeer.longLongValue != 0 && ![changedPeer isEqual:nodePeer]) continue;
        if (changedPeer && changedPeer.longLongValue == 0 && (!nodePeer || nodePeer.longLongValue <= -1000000000000LL)) continue;

        TGExtraScheduleMessageBadgeUpdate(node);
    }
}
@end

void TGExtraStartMessageBadges(void) { [TGExtraAntiRevokeUpdater shared]; }

%ctor {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC / 2), dispatch_get_main_queue(), ^{
        Class view = objc_getClass("_ASDisplayView");
        Method getter = class_getInstanceMethod(view, @selector(asyncdisplaykit_node));
        if (!getter || method_getNumberOfArguments(getter) != 2) {
            TGExtraRecordHookStatus(@"Message badges / paid media", @"unavailable: display view accessor");
            return;
        }
        TGExtraRecordHookStatus(@"Message badges / paid media",
            class_getInstanceMethod(view, @selector(layoutSubviews)) && class_getInstanceMethod(view, @selector(didMoveToWindow))
                ? @"installed" : @"partial: display view lifecycle");
        if (class_getInstanceMethod(view, @selector(layoutSubviews))) { %init(TGExtraMessageViewLayout, _ASDisplayView = view); }
        if (class_getInstanceMethod(view, @selector(didMoveToWindow))) { %init(TGExtraMessageViewWindow, _ASDisplayView = view); }
    });
}
