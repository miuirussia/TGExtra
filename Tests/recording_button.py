#!/usr/bin/env python3
"""Exercise recording-view removal, reattachment and accessibility on macOS."""
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parent.parent
source = (ROOT / 'Sources/tgapi/RecordingButton.xm').read_text()
helpers = source[source.index('static void TGExtraRemoveRecordingControls'):source.index('%group TGExtraRecordingButton')]
actions = source.split('%hook TGExtraRecordingActionButtonsNode\n', 1)[1].split('%end', 1)[0]
actions = actions.replace('%orig;', '[super didEnterHierarchy];', 1).replace('%orig', '[super isAccessibilityElement]')
button = source.split('%hook TGExtraMediaRecordingButton\n', 1)[1].split('%end', 1)[0]
button = button.replace('%orig;', '[super didMoveToSuperview];')

support = r'''
#import <Foundation/Foundation.h>
@interface UIView : NSObject
@property (nonatomic, weak) UIView *superview;
@property NSMutableArray<UIView *> *subviews;
@property (nonatomic, getter=isHidden) BOOL hidden;
@property CGFloat alpha;
@property BOOL userInteractionEnabled;
@property BOOL accessibilityElementsHidden;
@property NSUInteger movedCalls;
- (void)didMoveToSuperview;
- (void)addSubview:(UIView *)view;
- (void)removeFromSuperview;
@end
@implementation UIView
- (instancetype)init {
    if ((self = [super init])) {
        _subviews = [NSMutableArray new];
        _alpha = 1.0;
        _userInteractionEnabled = YES;
    }
    return self;
}
- (void)didMoveToSuperview { self.movedCalls++; }
- (void)addSubview:(UIView *)view {
    [view removeFromSuperview];
    [self.subviews addObject:view];
    view.superview = self;
    [view didMoveToSuperview];
}
- (void)removeFromSuperview {
    if (!self.superview) return;
    [self.superview.subviews removeObject:self];
    self.superview = nil;
    [self didMoveToSuperview];
}
@end
@interface UIControl : UIView
@property NSUInteger recordings;
- (void)micButtonInteractionBegan;
@end
@implementation UIControl
- (void)micButtonInteractionBegan { self.recordings++; }
@end
@interface HostActionNode : NSObject
@property NSDictionary *controls;
@property NSUInteger entered;
@property BOOL hostAccessible;
- (void)didEnterHierarchy;
- (BOOL)isAccessibilityElement;
@end
@implementation HostActionNode
- (void)didEnterHierarchy { self.entered++; }
- (BOOL)isAccessibilityElement { return self.hostAccessible; }
@end
@interface TGExtraRecordingActionButtonsNode : HostActionNode
@end
@interface TGExtraMediaRecordingButton : UIControl
@end
@interface TGExtraRecordingControls : NSObject
+ (NSDictionary *)fromNode:(HostActionNode *)node;
@end
@implementation TGExtraRecordingControls
+ (NSDictionary *)fromNode:(HostActionNode *)node { return node.controls; }
@end
'''

tests = r'''
int main(void) { @autoreleasepool {
    UIView *parent = [UIView new];
    TGExtraMediaRecordingButton *mic = [TGExtraMediaRecordingButton new];
    UIView *background = [UIView new];
    UIView *mask = [UIView new];
    UIView *send = [UIView new];
    UIView *expand = [UIView new];
    UIView *expandBackground = [UIView new];
    TGExtraRecordingActionButtonsNode *node = [TGExtraRecordingActionButtonsNode new];
    node.hostAccessible = YES;
    node.controls = @{@"micButton": mic, @"micButtonBackgroundView": background,
        @"micButtonTintMaskView": mask, @"sendContainerNode": send,
        @"expandMediaInputButton": expand, @"expandMediaInputButtonBackgroundView": expandBackground};
    [background addSubview:mic];
    NSCAssert(!mic.superview && mic.hidden && !mic.userInteractionEnabled,
        @"Detach the recording button immediately, before rendering");
    NSCAssert(mic.movedCalls == 2, @"Keep both host move callbacks, including removal");
    for (UIView *view in @[background, mask, send, expandBackground]) [parent addSubview:view];
    [expandBackground addSubview:expand];
    for (int i = 0; i < 3; i++) {
        [node didEnterHierarchy];
        for (UIView *view in @[mic, background, mask]) {
            NSCAssert(!view.superview && view.hidden && !view.userInteractionEnabled && view.accessibilityElementsHidden,
                @"Remove every recording view, including the separately rendered glass and mask");
        }
        NSCAssert(send.superview == parent && expand.superview == expandBackground && expandBackground.superview == parent,
            @"Keep send and media expansion attached and interactive");
        // Model subsequent native layout/animation writes, even when Swiftgram already set mic alpha to zero.
        mic.alpha = 0.0;
        mic.hidden = NO;
        mic.userInteractionEnabled = YES;
        background.alpha = 1.0;
        background.hidden = NO;
        mask.hidden = NO;
        [parent addSubview:mic];
        NSCAssert(!mic.superview && mic.hidden, @"Reattachment cannot revive the recording button");
        NSCAssert(!background.superview && !mask.superview, @"Geometry and opacity changes cannot restore detached views");
        [mic micButtonInteractionBegan];
        NSCAssert(mic.recordings == 0, @"Reject retained-button callbacks for both voice and video modes");
    }
    NSCAssert(node.entered == 3, @"Preserve original hierarchy callbacks");
    send.alpha = 0.0;
    expandBackground.alpha = 0.0;
    NSCAssert(!node.isAccessibilityElement, @"Do not announce the removed recording action");
    send.alpha = 1.0;
    NSCAssert(node.isAccessibilityElement, @"Keep the Send action accessible");
    send.hidden = YES;
    NSCAssert(!node.isAccessibilityElement, @"A hidden send button is not an available action");
    expandBackground.alpha = 1.0;
    NSCAssert(node.isAccessibilityElement, @"Keep visible media expansion accessible");
    node.hostAccessible = NO;
    NSCAssert(!node.isAccessibilityElement, @"Respect the host's own accessibility suppression");
    node.hostAccessible = YES;
    node.controls = @{@"expandMediaInputButton": expand};
    NSCAssert(node.isAccessibilityElement, @"Support older layouts without a separate expand background");
    node.controls = @{};
    [node didEnterHierarchy];
    NSCAssert(!node.isAccessibilityElement, @"Unknown fields are safe");
    // With the preference off the hooks are not installed: all host methods keep their behavior.
    UIControl *originalMic = [UIControl new];
    [parent addSubview:originalMic];
    [originalMic micButtonInteractionBegan];
    NSCAssert(originalMic.superview == parent && originalMic.recordings == 1, @"Default behavior remains usable");
    puts("PASS recording button detachment, glass/mask removal, reattachment, native animations, callbacks and accessibility");
} }
'''

swift_tests = r'''
import Foundation
class LegacyActions {
    let micButton = NSObject()
}
final class GlassActions: LegacyActions {
    let micButtonBackgroundView = NSObject()
    let micButtonTintMaskView: NSObject? = NSObject()
    let sendContainerNode = NSObject()
    let expandMediaInputButton = NSObject()
    let expandMediaInputButtonBackgroundView = NSObject()
    let sendButton = NSObject()
}
let node = GlassActions()
let fields = TGExtraRecordingControls.fromNode(node)
precondition(fields.count == 6)
precondition(fields["micButton"] as? NSObject === node.micButton)
precondition(fields["micButtonTintMaskView"] as? NSObject === node.micButtonTintMaskView)
precondition(fields["sendContainerNode"] as? NSObject === node.sendContainerNode)
precondition(fields["sendButton"] == nil)
precondition(TGExtraRecordingControls.fromNode(LegacyActions()).count == 1)
precondition(TGExtraRecordingControls.fromNode(NSObject()).isEmpty)
print("PASS stored recording controls in current/legacy host layouts, inherited fields and optionals")
'''

with tempfile.TemporaryDirectory(prefix='tgextra-recording-') as tmp:
    work = Path(tmp)
    harness = work / 'recording.m'
    harness.write_text(support + helpers + '@implementation TGExtraRecordingActionButtonsNode\n' + actions
                       + '@end\n@implementation TGExtraMediaRecordingButton\n' + button + '@end\n' + tests)
    binary = work / 'recording-tests'
    subprocess.run(['clang', '-fobjc-arc', '-Werror', '-framework', 'Foundation',
                    str(harness), '-o', str(binary)], check=True)
    subprocess.run([str(binary)], check=True)
    (work / 'main.swift').write_text(swift_tests)
    subprocess.run(['swiftc', str(ROOT / 'Sources/tgapi/HostValueReader.swift'),
                    str(ROOT / 'Sources/tgapi/RecordingControls.swift'),
                    str(work / 'main.swift'), '-o', str(binary)], check=True)
    subprocess.run([str(binary)], check=True)
