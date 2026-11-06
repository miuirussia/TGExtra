#!/usr/bin/env python3
"""Exercise the message gesture hooks with UIKit state transitions on macOS."""
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parent.parent
source = (ROOT / 'Sources/tgapi/DoubleTapReactions.x').read_text()
helper = source[source.index('static char kTGExtraMessageTouchesBegan;'):source.index('%group TGExtraDoubleTapReactions')]
hooks = source[source.index('%hook TGExtraReactionTapRecognizer'):source.index('%end')]
hooks = hooks.replace('%hook TGExtraReactionTapRecognizer', '@implementation TGExtraReactionTapRecognizer')
hooks = hooks.replace('%orig;', '[super touchesBegan:touches withEvent:event];')
hooks = hooks.replace('%orig(state);', '[super setState:state];') + '@end\n'
state_hook = ''
if '%hook UIGestureRecognizer\n' in source:
    state_hook = source.split('%hook UIGestureRecognizer\n', 1)[1].split('%end', 1)[0]
    state_hook = state_hook.replace('- (void)setState:(UIGestureRecognizerState)state {', '''
static void (*originalState)(id, SEL, UIGestureRecognizerState);
static void setStateHook(UIGestureRecognizer *self, SEL _cmd, UIGestureRecognizerState state) {''')
    state_hook = state_hook.replace('%orig(state);', 'originalState(self, _cmd, state);')

support = r'''
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import "Constants.h"
typedef NS_ENUM(NSInteger, UIGestureRecognizerState) {
    UIGestureRecognizerStatePossible, UIGestureRecognizerStateBegan,
    UIGestureRecognizerStateChanged, UIGestureRecognizerStateEnded,
    UIGestureRecognizerStateCancelled, UIGestureRecognizerStateFailed
};
@interface UIView : NSObject
@end
@implementation UIView
@end
@interface UIView (TGExtraReactionMessageNode)
- (id)asyncdisplaykit_node;
@end
@interface MessageView : UIView
@property id node;
- (id)asyncdisplaykit_node;
@end
@implementation MessageView
- (id)asyncdisplaykit_node { return self.node; }
@end
@interface UIEvent : NSObject
@property UIGestureRecognizerState nextState;
@property BOOL throws;
@property BOOL callsSuperSetter;
@property id otherRecognizer;
@end
@implementation UIEvent
@end
@interface UITouch : NSObject
@end
@implementation UITouch
@end
@interface UIGestureRecognizer : NSObject
@property UIView *view;
@property (nonatomic) UIGestureRecognizerState state;
@property NSUInteger reactions;
@property NSUInteger cancellations;
@property NSUInteger beganCalls;
- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event;
@end
@implementation UIGestureRecognizer
- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {}
- (void)setState:(UIGestureRecognizerState)state {
    _state = state;
    if (state == UIGestureRecognizerStateEnded) self.reactions++;
    if (state == UIGestureRecognizerStateCancelled) self.cancellations++;
}
@end
@interface HostReactionTapRecognizer : UIGestureRecognizer
@end
@implementation HostReactionTapRecognizer
- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    self.beganCalls++;
    if (event.throws) @throw [NSException exceptionWithName:@"HostError" reason:nil userInfo:nil];
    [event.otherRecognizer setState:UIGestureRecognizerStateEnded];
    if (event.callsSuperSetter) [super setState:event.nextState];
    else self.state = event.nextState;
}
- (void)setState:(UIGestureRecognizerState)state { [super setState:state]; }
@end
@interface TGExtraReactionTapRecognizer : HostReactionTapRecognizer
@end
'''

tests = r'''
int main(int argc, const char *argv[]) {
    @autoreleasepool {
        BOOL callsSuperSetter = argc > 1 && strcmp(argv[1], "super") == 0;
        NSString *domain = [@"TGExtraGestureTests." stringByAppendingString:NSUUID.UUID.UUIDString];
        NSUserDefaults *defaults = [[NSUserDefaults alloc] initWithSuiteName:domain];
        Method method = class_getClassMethod(NSUserDefaults.class, @selector(standardUserDefaults));
        IMP original = method_setImplementation(method, imp_implementationWithBlock(^id(id cls) { return defaults; }));
        NSCAssert(![defaults boolForKey:kDisableDoubleTapReactions], @"Default off");
        INSTALL_STATE_HOOK
        UIEvent *doubleTap = [UIEvent new];
        doubleTap.nextState = UIGestureRecognizerStateEnded;
        doubleTap.callsSuperSetter = callsSuperSetter;
        for (NSString *name in @[@"TelegramUI.ChatMessageBubbleItemNode",
             @"ChatMessageStickerItemNode.ChatMessageStickerItemNode",
             @"ChatMessageAnimatedStickerItemNode.ChatMessageAnimatedStickerItemNode"]) {
            Class nodeClass = objc_allocateClassPair(NSObject.class, name.UTF8String, 0);
            objc_registerClassPair(nodeClass);
            MessageView *view = [MessageView new];
            view.node = [nodeClass new];
            TGExtraReactionTapRecognizer *recognizer = [TGExtraReactionTapRecognizer new];
            recognizer.view = view;
            for (NSNumber *disabled in @[@NO, @YES, @NO]) {
                [defaults setBool:disabled.boolValue forKey:kDisableDoubleTapReactions];
                NSUInteger reactions = recognizer.reactions;
                NSUInteger cancellations = recognizer.cancellations;
                [recognizer touchesBegan:[NSSet set] withEvent:doubleTap];
                NSCAssert(recognizer.reactions == reactions + !disabled.boolValue, @"Cancel only enabled double-tap reactions");
                NSCAssert(recognizer.cancellations == cancellations + disabled.boolValue, @"Cancel before the host sends a reaction");
                recognizer.state = UIGestureRecognizerStateEnded;
                NSCAssert(recognizer.reactions == reactions + !disabled.boolValue + 1, @"A later single-tap/timer callback must still run");
            }
            [defaults setBool:YES forKey:kDisableDoubleTapReactions];
            for (NSNumber *state in @[@(UIGestureRecognizerStatePossible), @(UIGestureRecognizerStateBegan),
                 @(UIGestureRecognizerStateChanged), @(UIGestureRecognizerStateFailed)]) {
                UIEvent *event = [UIEvent new];
                event.nextState = (UIGestureRecognizerState)state.integerValue;
                event.callsSuperSetter = callsSuperSetter;
                [recognizer touchesBegan:[NSSet set] withEvent:event];
                NSCAssert(recognizer.state == event.nextState, @"Preserve waiting, long-press and rejected-touch transitions");
            }
            NSCAssert(recognizer.beganCalls == 7, @"Always run Telegram's touch handling");
            UIEvent *failure = [UIEvent new];
            failure.throws = YES;
            @try { [recognizer touchesBegan:[NSSet set] withEvent:failure]; }
            @catch (NSException *exception) {}
            NSUInteger reactions = recognizer.reactions;
            recognizer.state = UIGestureRecognizerStateEnded;
            NSCAssert(recognizer.reactions == reactions + 1, @"Even an interrupted touch must not block later actions");
        }
        TGExtraReactionTapRecognizer *other = [TGExtraReactionTapRecognizer new];
        MessageView *unrelated = [MessageView new];
        unrelated.node = [NSObject new];
        for (id view in @[[UIView new], unrelated, NSNull.null]) {
            other.view = view == NSNull.null ? nil : view;
            NSUInteger reactions = other.reactions;
            [other touchesBegan:[NSSet set] withEvent:doubleTap];
            NSCAssert(other.reactions == reactions + 1, @"Leave other recognizer uses, including media zoom, alone");
        }
        UIGestureRecognizer *unrelatedRecognizer = [UIGestureRecognizer new];
        MessageView *message = [MessageView new];
        message.node = [NSClassFromString(@"TelegramUI.ChatMessageBubbleItemNode") new];
        other.view = message;
        doubleTap.otherRecognizer = unrelatedRecognizer;
        NSUInteger cancellations = other.cancellations;
        [other touchesBegan:[NSSet set] withEvent:doubleTap];
        NSCAssert(other.cancellations == cancellations + 1, @"Cancel the marked message gesture");
        NSCAssert(unrelatedRecognizer.reactions == 1, @"Keep unrelated recognizers active inside the marked callback");
        method_setImplementation(method, original);
        [defaults removePersistentDomainForName:domain];
        printf("PASS message double-tap cancellation (%s setter), off/on/off, other gestures and views\n",
            callsSuperSetter ? "super" : "self");
    }
}
'''
tests = tests.replace('INSTALL_STATE_HOOK', '''
        Method state = class_getInstanceMethod(UIGestureRecognizer.class, @selector(setState:));
        originalState = (void (*)(id, SEL, UIGestureRecognizerState))method_setImplementation(state, (IMP)setStateHook);
''' if state_hook else '')

with tempfile.TemporaryDirectory(prefix='tgextra-double-tap-') as tmp:
    work = Path(tmp)
    harness = work / 'gestures.m'
    harness.write_text(support + helper + hooks + state_hook + tests)
    binary = work / 'gesture-tests'
    subprocess.run(['clang', '-fobjc-arc', '-Werror', '-framework', 'Foundation',
                    '-I' + str(ROOT / 'Sources/tgapi'), str(harness), '-o', str(binary)], check=True)
    for setter in ('self', 'super'):
        subprocess.run([str(binary), setter], check=True)
