#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import "Constants.h"
#import "RecordingInputLayout.h"

@interface TGExtraRecordingControls : NSObject
+ (NSDictionary<NSString *, id> *)fromNode:(id)node;
@end

@interface TGExtraRecordingActionButtonsNode : NSObject
- (void)didEnterHierarchy;
- (BOOL)isAccessibilityElement;
@end

@interface TGExtraMediaRecordingButton : UIControl
- (void)micButtonInteractionBegan;
@end

@interface TGExtraRecordingInputPanelNode : NSObject
- (void)didLoad;
- (void)didEnterHierarchy;
@end

@interface TGExtraRecordingInputGlassView : UIView
@end

static void TGExtraRemoveRecordingControls(id node) {
    NSDictionary *controls = [TGExtraRecordingControls fromNode:node];
    for (NSString *key in @[@"micButton", @"micButtonBackgroundView", @"micButtonTintMaskView"]) {
        UIView *view = controls[key];
        if (![view isKindOfClass:UIView.class]) continue;
        view.hidden = YES;
        view.userInteractionEnabled = NO;
        view.accessibilityElementsHidden = YES;
        [view removeFromSuperview];
    }
}

static BOOL TGExtraHasVisibleNonRecordingAction(id node) {
    NSDictionary *controls = [TGExtraRecordingControls fromNode:node];
    // The glass background owns the expand button's visibility in current clients.
    id expand = controls[@"expandMediaInputButtonBackgroundView"] ?: controls[@"expandMediaInputButton"];
    for (id control in @[controls[@"sendContainerNode"] ?: NSNull.null, expand ?: NSNull.null]) {
        if (![control respondsToSelector:@selector(alpha)] ||
            ![control respondsToSelector:@selector(isHidden)]) continue;
        // ASDisplayNode and UIView expose the same visibility selectors.
        UIView *action = control;
        if (!action.isHidden && action.alpha > 0.01) return YES;
    }
    return NO;
}

// Telegram / Swiftgram 13.1.1 share these classes and stored field names.
// Swiftgram's hideRecordingButton changes layout/alpha but keeps the views.
// Detach just the recording views: later frame and opacity animations cannot
// bring them back, while the send and media-expansion controls remain attached.
%group TGExtraRecordingButton
%hook TGExtraRecordingActionButtonsNode
- (void)didEnterHierarchy {
    %orig;
    TGExtraRemoveRecordingControls(self);
}

- (BOOL)isAccessibilityElement {
    if (!TGExtraHasVisibleNonRecordingAction(self)) return NO;
    return %orig;
}
%end

%hook TGExtraMediaRecordingButton
- (void)didMoveToSuperview {
    %orig;
    UIView *view = (UIView *)self;
    if (view.superview) {
        view.hidden = YES;
        view.userInteractionEnabled = NO;
        view.accessibilityElementsHidden = YES;
        [view removeFromSuperview];
    }
}

- (void)micButtonInteractionBegan {
    // Also reject a direct delegate/accessibility invocation on the retained button.
}
%end
%end

%group TGExtraRecordingInputLayout
%hook TGExtraRecordingInputPanelNode
- (void)didLoad {
    %orig;
    TGExtraBindRecordingInput(self);
}

- (void)didEnterHierarchy {
    %orig;
    TGExtraBindRecordingInput(self);
}
%end

%hook TGExtraRecordingInputGlassView
- (void)layoutSubviews {
    %orig;
    TGExtraLayoutRecordingInput((UIView *)self);
}
%end
%end

__attribute__((constructor)) static void TGExtraInstallRecordingButton(void) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC / 2), dispatch_get_main_queue(), ^{
        TGExtraRestorePreferences();
        // Removing views lasts for this process. Apply restarts the client when
        // enabling or disabling the option, restoring the host's own layout.
        if (![NSUserDefaults.standardUserDefaults boolForKey:kHideRecordingButton]) return;
        Class actions = NSClassFromString(@"ChatTextInputActionButtonsNode.ChatTextInputActionButtonsNode")
            ?: NSClassFromString(@"TelegramUI.ChatTextInputActionButtonsNode");
        Class button = NSClassFromString(@"ChatTextInputMediaRecordingButton.ChatTextInputMediaRecordingButton")
            ?: NSClassFromString(@"TelegramUI.ChatTextInputMediaRecordingButton");
        Method enter = class_getInstanceMethod(actions, @selector(didEnterHierarchy));
        Method accessible = class_getInstanceMethod(actions, @selector(isAccessibilityElement));
        Method moved = class_getInstanceMethod(button, @selector(didMoveToSuperview));
        Method began = class_getInstanceMethod(button, @selector(micButtonInteractionBegan));
        if (enter && method_getNumberOfArguments(enter) == 2 &&
            accessible && method_getNumberOfArguments(accessible) == 2 &&
            moved && method_getNumberOfArguments(moved) == 2 &&
            began && method_getNumberOfArguments(began) == 2) {
            %init(TGExtraRecordingButton, TGExtraRecordingActionButtonsNode = actions, TGExtraMediaRecordingButton = button);
            Class panel = NSClassFromString(@"ChatTextInputPanelNode.ChatTextInputPanelNode")
                ?: NSClassFromString(@"TelegramUI.ChatTextInputPanelNode");
            Class glass = NSClassFromString(@"GlassBackgroundComponent.GlassBackgroundView");
            if (class_getInstanceMethod(panel, @selector(didLoad)) &&
                class_getInstanceMethod(panel, @selector(didEnterHierarchy)) &&
                class_getInstanceMethod(glass, @selector(layoutSubviews))) {
                %init(TGExtraRecordingInputLayout, TGExtraRecordingInputPanelNode = panel, TGExtraRecordingInputGlassView = glass);
            }
        }
    });
}
