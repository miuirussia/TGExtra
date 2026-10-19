#!/usr/bin/env python3
"""Exercise the real backing-view lifecycle, scheduler and notification updater on macOS."""
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parent.parent
source = (ROOT / 'Sources/tgapi/UI/UIHooks.xm').read_text()
updater = source[source.index('static NSHashTable *activeMessageNodes = nil;'):]
updater = updater[:updater.index('// ============================================================')]
for group, method in [('TGExtraMessageViewLayout', 'layoutSubviews'), ('TGExtraMessageViewWindow', 'didMoveToWindow')]:
    updater = updater.replace(f'%group {group}\n%hook _ASDisplayView', f'@implementation _ASDisplayView ({group})', 1)
    updater = updater.replace('%orig;', f'[super {method}];', 1)
    updater = updater.replace('%end\n%end', '@end', 1)
assert '%' not in updater, 'Only Objective-C runtime hooks may drive message updates'
bindings = source[source.index('static char kTGExtraEditMsgIdKey;'):source.index('@interface TGExtraEditHistoryButtonTarget')]
geometry = source[source.index('static CGRect tgextraEditBadgeFrame('):source.index('/// Places, or hides, the pencil badge')]

support = r'''
#import <Foundation/Foundation.h>
#import <CoreFoundation/CoreFoundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import <objc/runtime.h>

@class ASDisplayNode;
@interface UIView : NSObject
@property NSInteger tag;
@property BOOL hidden;
@property NSArray *subviews;
@property (weak) ASDisplayNode *node;
@property NSUInteger originalLayouts;
@property NSUInteger originalWindowMoves;
- (void)layoutSubviews;
- (void)didMoveToWindow;
@end
@implementation UIView
- (void)layoutSubviews { self.originalLayouts++; }
- (void)didMoveToWindow { self.originalWindowMoves++; }
- (ASDisplayNode *)asyncdisplaykit_node { return self.node; }
@end
@interface UIButton : UIView
@end
@implementation UIButton
@end
@interface _ASDisplayView : UIView
@end
@implementation _ASDisplayView
@end
@interface ASDisplayNode : NSObject
@property _ASDisplayView *view;
@property NSNumber *messageID;
@property NSNumber *peer;
@property NSString *account;
@property NSNumber *messageNamespace;
@property NSUInteger refreshCount;
@property NSUInteger statusRefreshCount;
@property NSUInteger snapshotCount;
@property NSNumber *drawnID;
@end
@implementation ASDisplayNode
- (instancetype)init {
    if ((self = [super init])) {
        self.view = [_ASDisplayView new];
        self.view.node = self;
        self.messageID = @10;
        self.peer = @42;
        self.account = @"account-1";
        self.messageNamespace = @0;
    }
    return self;
}
// Deliberately has neither -layout nor -didEnterHierarchy.
@end
@interface ChatMessageBubbleItemNode : ASDisplayNode
@end
@implementation ChatMessageBubbleItemNode
@end
@interface TLParser : NSObject
+ (NSDictionary *)messageStateFromNode:(ASDisplayNode *)node observe:(BOOL)observe;
@end
@implementation TLParser
+ (NSDictionary *)messageStateFromNode:(ASDisplayNode *)node observe:(BOOL)observe {
    if (observe) node.snapshotCount++;
    if (!node.messageID || !node.peer || !node.account || !node.messageNamespace) return nil;
    return @{@"id": node.messageID, @"peer": node.peer, @"account": node.account, @"namespace": node.messageNamespace};
}
@end
static void updateTGExtraStatusBadge(ASDisplayNode *node, NSNumber *msgId, NSNumber *peer, NSString *account, NSNumber *ns) {
    NSCAssert(NSThread.isMainThread, @"Status updates must run on main");
    node.statusRefreshCount++;
}
static void updateTGExtraEditBadge(ASDisplayNode *node, NSNumber *msgId, NSNumber *peer, NSString *account, NSNumber *ns) {
    NSCAssert(NSThread.isMainThread, @"Badge updates must run on main");
    NSCAssert(!msgId || ([peer isEqual:node.peer] && [account isEqual:node.account] && [ns isEqual:node.messageNamespace]), @"Use one current item's complete identity");
    node.refreshCount++;
    node.drawnID = msgId;
}
'''

tests = r'''
static void drainMainQueue(void) {
    CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.01, false);
}
int main(void) {
    @autoreleasepool {
        [TGExtraAntiRevokeUpdater shared];
        ChatMessageBubbleItemNode *node = [ChatMessageBubbleItemNode new];
        node.messageID = nil;
        [node.view didMoveToWindow];
        [node.view layoutSubviews];
        [node.view layoutSubviews];
        node.messageID = @10;
        drainMainQueue();
        NSCAssert(node.refreshCount == 1 && node.snapshotCount == 1 && [node.drawnID isEqual:@10],
                  @"Coalesce backing-view events and observe the latest item without ASDisplayNode.layout");
        NSCAssert(node.view.originalLayouts == 2 && node.view.originalWindowMoves == 1, @"Original view methods must run");
        NSCAssert([activeMessageNodes containsObject:node], @"An attached view must register for later edits");
        ASDisplayNode *unrelated = [ASDisplayNode new];
        [unrelated.view layoutSubviews];
        [unrelated.view didMoveToWindow];
        drainMainQueue();
        NSCAssert(unrelated.snapshotCount == 0 && ![activeMessageNodes containsObject:unrelated], @"Ignore non-message nodes");

        ChatMessageBubbleItemNode *otherAccount = [ChatMessageBubbleItemNode new];
        otherAccount.account = @"account-2";
        [otherAccount.view didMoveToWindow];
        ChatMessageBubbleItemNode *otherChat = [ChatMessageBubbleItemNode new];
        otherChat.peer = @43;
        [otherChat.view didMoveToWindow];
        drainMainQueue();
        [[NSNotificationCenter defaultCenter] postNotificationName:@"TGExtraMessageEditedRealtime"
            object:nil userInfo:@{@"ids": @[@10], @"account": @"account-1", @"peer": @42}];
        drainMainQueue();
        NSCAssert(node.refreshCount == 2 && node.statusRefreshCount == 2, @"Notifications refresh directly without node layout");
        NSCAssert(otherAccount.refreshCount == 1 && otherChat.refreshCount == 1, @"Isolate accounts and chats");

        [node.view layoutSubviews];
        [node.view layoutSubviews];
        node.messageID = @11;
        node.peer = @44;
        drainMainQueue();
        NSCAssert(node.refreshCount == 3 && [node.drawnID isEqual:@11], @"Read identity after queued reuse");
        node.messageID = @12;
        [[NSNotificationCenter defaultCenter] postNotificationName:@"TGExtraMessageEditedRealtime"
            object:nil userInfo:@{@"ids": @[@12], @"account": @"account-1", @"peer": @44}];
        node.messageID = @13;
        drainMainQueue();
        NSCAssert([node.drawnID isEqual:@13], @"Notification refresh must not draw a previous item");
        node.messageID = nil;
        [node.view layoutSubviews];
        drainMainQueue();
        NSCAssert(node.drawnID == nil, @"An unbound reused node must clear its drawn identity");

        ChatMessageBubbleItemNode *scheduled = [ChatMessageBubbleItemNode new];
        scheduled.messageNamespace = @3;
        [scheduled.view didMoveToWindow];
        drainMainQueue();
        [[NSNotificationCenter defaultCenter] postNotificationName:@"TGExtraMessageEditedRealtime"
            object:nil userInfo:@{@"ids": @[@10], @"account": @"account-1", @"peer": @42, @"namespace": @0}];
        drainMainQueue();
        NSCAssert(scheduled.refreshCount == 1, @"Namespace isolation");
        ChatMessageBubbleItemNode *channel = [ChatMessageBubbleItemNode new];
        channel.peer = @(-1000000000077LL);
        [channel.view didMoveToWindow];
        drainMainQueue();
        [[NSNotificationCenter defaultCenter] postNotificationName:@"TGExtraMessageDeletedRealtime"
            object:nil userInfo:@{@"maxId": @10, @"account": @"account-1", @"peer": @(-1000000000077LL), @"namespace": @0}];
        drainMainQueue();
        NSCAssert(channel.statusRefreshCount == 2, @"Range deletion refreshes the visible status directly");

        UIButton *badge = [UIButton new];
        objc_setAssociatedObject(badge, &kTGExtraEditMsgIdKey, @10, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(badge, &kTGExtraEditPeerKey, @42, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(badge, &kTGExtraEditAccountKey, @"account-1", OBJC_ASSOCIATION_COPY_NONATOMIC);
        objc_setAssociatedObject(badge, &kTGExtraEditNamespaceKey, @0, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        node.view.subviews = @[badge];
        badge.tag = 8899;
        [[NSNotificationCenter defaultCenter] postNotificationName:@"TGExtraMessageDataCleared" object:nil];
        NSCAssert(badge.hidden && !objc_getAssociatedObject(badge, &kTGExtraEditMsgIdKey) &&
                  !objc_getAssociatedObject(badge, &kTGExtraEditPeerKey) &&
                  !objc_getAssociatedObject(badge, &kTGExtraEditAccountKey) &&
                  !objc_getAssociatedObject(badge, &kTGExtraEditNamespaceKey), @"Clear every button binding");

        CGRect boundsCases[] = { CGRectMake(0, 0, 200, 60), CGRectMake(10, 20, 30, 24) };
        for (CGRect bounds : boundsCases) {
            for (int hasStatus = 0; hasStatus < 2; hasStatus++) {
                CGRect frame = tgextraEditBadgeFrame(bounds, CGRectMake(230, -50, 20, 10), hasStatus);
                NSCAssert(CGRectContainsRect(bounds, frame), @"Full touch target stays within both axes of the message view");
            }
        }
        puts("PASS backing-view lifecycle, coalescing, snapshots, direct notifications, reuse, bindings and touch bounds");
    }
    return 0;
}
'''

with tempfile.TemporaryDirectory(prefix='tgextra-badge-') as tmp:
    path = Path(tmp)
    harness = path / 'badge.mm'
    harness.write_text(support + bindings + geometry + updater + tests)
    binary = path / 'badge-tests'
    subprocess.run(['clang++', '-std=c++11', '-fobjc-arc', '-Werror', '-framework', 'Foundation',
                    '-framework', 'CoreFoundation', '-framework', 'CoreGraphics', str(harness), '-o', str(binary)], check=True)
    subprocess.run([str(binary)], check=True)
