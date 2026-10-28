#import <UIKit/UIKit.h>
#import <UIKit/UIGestureRecognizerSubclass.h>
#import <objc/runtime.h>
#import "Constants.h"

@interface UIView (TGExtraReactionMessageNode)
- (id)asyncdisplaykit_node;
@end

@interface TGExtraReactionTapRecognizer : UIGestureRecognizer
@end

static char kTGExtraMessageTouchesBegan;

static BOOL TGExtraShouldDisableDoubleTap(UIGestureRecognizer *recognizer) {
    if (![NSUserDefaults.standardUserDefaults boolForKey:kDisableDoubleTapReactions]) return NO;
    UIView *view = recognizer.view;
    if (![view respondsToSelector:@selector(asyncdisplaykit_node)]) return NO;
    NSString *name = NSStringFromClass([[view asyncdisplaykit_node] class]);
    return [name hasSuffix:@".ChatMessageBubbleItemNode"] ||
        [name hasSuffix:@".ChatMessageStickerItemNode"] ||
        [name hasSuffix:@".ChatMessageAnimatedStickerItemNode"];
}

// Telegram-iOS fb0e62ba8a147f0821da6aa63c09da7d79a10111:
// submodules/Display/Source/TapLongTapOrDoubleTapGestureRecognizer.swift
// Only .doubleTap sets .ended inside touchesBegan. Single taps finish in
// touchesEnded/tapEvent; long taps use longTapEvent. Intercept the UIKit state
// setter during that call so no Swift enum layout or stored offsets are needed.
// Verified in decrypted Telegram 13.1.1 (35634) / Swiftgram 13.1.1 (343):
// touchesBegan has an Objective-C entry and the double-tap branch dispatches
// setState: through objc_msgSend. Logos's internal generator needs no Substrate.
%group TGExtraDoubleTapReactions
%hook TGExtraReactionTapRecognizer
- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    if (!TGExtraShouldDisableDoubleTap(self)) {
        %orig;
        return;
    }
    id previous = objc_getAssociatedObject(self, &kTGExtraMessageTouchesBegan);
    objc_setAssociatedObject(self, &kTGExtraMessageTouchesBegan, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    @try {
        %orig;
    } @finally {
        objc_setAssociatedObject(self, &kTGExtraMessageTouchesBegan, previous, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
}

- (void)setState:(UIGestureRecognizerState)state {
    if (state == UIGestureRecognizerStateEnded &&
        [objc_getAssociatedObject(self, &kTGExtraMessageTouchesBegan) boolValue]) {
        state = UIGestureRecognizerStateCancelled;
    }
    %orig(state);
}
%end
%end

__attribute__((constructor)) static void TGExtraInstallDoubleTapReactions(void) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC / 2), dispatch_get_main_queue(), ^{
        Class recognizer = NSClassFromString(@"Display.TapLongTapOrDoubleTapGestureRecognizer");
        Method began = class_getInstanceMethod(recognizer, @selector(touchesBegan:withEvent:));
        Method state = class_getInstanceMethod(recognizer, @selector(setState:));
        if (began && method_getNumberOfArguments(began) == 4 &&
            state && method_getNumberOfArguments(state) == 3) {
            %init(TGExtraDoubleTapReactions, TGExtraReactionTapRecognizer = recognizer);
        }
    });
}
