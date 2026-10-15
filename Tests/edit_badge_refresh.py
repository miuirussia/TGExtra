#!/usr/bin/env python3
"""Exercise the UI hook's refresh lifecycle with Foundation-only node doubles."""
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parent.parent
source = (ROOT / 'Sources/tgapi/UI/UIHooks.xm').read_text()
updater = source[source.index('static NSHashTable *activeMessageNodes = nil;'):]
updater = updater[:updater.index('// ============================================================')]
hook = source.rsplit('%hook ASDisplayNode\n', 1)[1]
attach = hook[:hook.index('- (void)layout {')].replace('%orig;', '')

support = r'''
#import <Foundation/Foundation.h>
#import <CoreFoundation/CoreFoundation.h>

@interface UIView : NSObject
@property NSInteger tag;
@property BOOL hidden;
@property NSArray *subviews;
- (void)setNeedsLayout;
@end
@implementation UIView
- (void)setNeedsLayout {}
@end

@interface ASDisplayNode : NSObject
@property UIView *view;
@property NSNumber *messageID;
@property NSNumber *peer;
@property NSString *account;
@property NSUInteger refreshCount;
@property NSNumber *drawnID;
- (void)setNeedsLayout;
@end
@implementation ASDisplayNode
- (instancetype)init {
    if ((self = [super init])) {
        self.view = [UIView new];
        self.messageID = @10;
        self.peer = @42;
        self.account = @"account-1";
    }
    return self;
}
- (void)setNeedsLayout {} // Deliberately never invokes -layout.
@end

@interface TLParser : NSObject
+ (NSNumber *)getMessageIdFromNode:(ASDisplayNode *)node;
+ (NSNumber *)getMessagePeerKeyFromNode:(ASDisplayNode *)node;
+ (NSString *)getHistoryAccountFromNode:(ASDisplayNode *)node;
@end
@implementation TLParser
+ (NSNumber *)getMessageIdFromNode:(ASDisplayNode *)node { return node.messageID; }
+ (NSNumber *)getMessagePeerKeyFromNode:(ASDisplayNode *)node { return node.peer; }
+ (NSString *)getHistoryAccountFromNode:(ASDisplayNode *)node { return node.account; }
@end

static void updateTGExtraEditBadge(ASDisplayNode *node, NSNumber *msgId, NSNumber *peerKey) {
    NSCAssert(NSThread.isMainThread, @"Badge updates must run on main");
    NSCAssert([peerKey isEqual:node.peer], @"Use the current item's peer");
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
        [node didEnterHierarchy];
        node.messageID = @10;
        drainMainQueue();
        NSCAssert(node.refreshCount == 1 && [node.drawnID isEqual:@10],
                  @"Attaching must refresh persisted history without any layout or reaction");
        NSCAssert([activeMessageNodes containsObject:node],
                  @"An attached node must receive later edit notifications without a layout");

        ChatMessageBubbleItemNode *otherAccount = [ChatMessageBubbleItemNode new];
        otherAccount.account = @"account-2";
        [otherAccount didEnterHierarchy];
        ChatMessageBubbleItemNode *otherChat = [ChatMessageBubbleItemNode new];
        otherChat.peer = @43;
        [otherChat didEnterHierarchy];
        drainMainQueue();
        [[NSNotificationCenter defaultCenter] postNotificationName:@"TGExtraMessageEditedRealtime"
            object:nil userInfo:@{@"ids": @[@10], @"account": @"account-1", @"peer": @42}];
        drainMainQueue();
        NSCAssert(node.refreshCount == 2, @"A visible edit must refresh directly without layout");
        NSCAssert(otherAccount.refreshCount == 1 && otherChat.refreshCount == 1,
                  @"Matching message IDs in other accounts and chats must not refresh");

        scheduleTGExtraEditBadgeUpdate(node);
        node.messageID = @11;
        node.peer = @44;
        drainMainQueue();
        NSCAssert([node.drawnID isEqual:@11], @"Read identity after queued node reuse");

        node.messageID = @12;
        [[NSNotificationCenter defaultCenter] postNotificationName:@"TGExtraMessageEditedRealtime"
            object:nil userInfo:@{@"ids": @[@12], @"account": @"account-1", @"peer": @44}];
        node.messageID = @13;
        drainMainQueue();
        NSCAssert([node.drawnID isEqual:@13], @"Notification refresh must not draw the previous item");
        puts("PASS edit badge attachment, direct notifications, account/chat isolation and queued reuse");
    }
    return 0;
}
'''

with tempfile.TemporaryDirectory(prefix='tgextra-badge-', dir='/private/tmp') as tmp:
    path = Path(tmp)
    harness = path / 'badge.mm'
    harness.write_text(support + updater + '''
@interface ChatMessageBubbleItemNode : ASDisplayNode
- (void)didEnterHierarchy;
@end
@implementation ChatMessageBubbleItemNode
''' + attach + '\n@end\n' + tests)
    binary = path / 'badge-tests'
    subprocess.run(['clang++', '-fobjc-arc', '-Werror', '-framework', 'Foundation',
                    '-framework', 'CoreFoundation', str(harness), '-o', str(binary)], check=True)
    subprocess.run([str(binary)], check=True)
