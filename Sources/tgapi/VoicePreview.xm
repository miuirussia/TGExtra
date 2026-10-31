#import "Compatibility.h"
#import "Headers.h"
#import "UI/Headers.h"
#import "VoiceSelection.h"
#import "VideoAudioExtractor.h"
#import <objc/message.h>

@interface TGMediaPickerGalleryInterfaceView : UIView
@end

static const void *kTGExtraVoicePreviewItemKey = &kTGExtraVoicePreviewItemKey;
#define kTGExtraVoiceButtonTag 8877
#define kTGExtraRoundButtonTag 8878
static const CGFloat kTGExtraVoiceButtonSide = 44.0;

static const void *kTGExtraItemIsVideoKey = &kTGExtraItemIsVideoKey;

static BOOL tgextraItemIsVideo(id item) {
    if (!item) return NO;
    if ([NSStringFromClass([item class]) containsString:@"Video"]) return YES;

    SEL backing = NSSelectorFromString(@"backingItem");
    if ([item respondsToSelector:backing]) {
        id inner = ((id (*)(id, SEL))objc_msgSend)(item, backing);
        if (inner) return [NSStringFromClass([inner class]) containsString:@"Video"];
    }
    return NO;
}

static void tgextraStyleVoiceButton(UIButton *button, BOOL enabled) {
    UIImage *icon = [UIImage systemImageNamed:@"waveform"];
    UIImageSymbolConfiguration *cfg =
        [UIImageSymbolConfiguration configurationWithPointSize:18
                                                        weight:UIImageSymbolWeightSemibold];
    if (cfg && icon) icon = [icon imageByApplyingSymbolConfiguration:cfg];
    [button setImage:icon forState:UIControlStateNormal];
    button.tintColor = [UIColor whiteColor];
    button.backgroundColor = enabled ? [UIColor systemBlueColor]
                                     : [UIColor colorWithWhite:0.0 alpha:0.5];
}

static void tgextraStyleRoundButton(UIButton *button, BOOL enabled) {
    tgextraStyleVoiceButton(button, enabled);
    [button setImage:[UIImage systemImageNamed:enabled ? @"video.circle.fill" : @"video.circle"]
           forState:UIControlStateNormal];
}

@interface TGExtraVoiceToggleTarget : NSObject
+ (instancetype)shared;
@end

@implementation TGExtraVoiceToggleTarget

+ (instancetype)shared {
    static TGExtraVoiceToggleTarget *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ instance = [self new]; });
    return instance;
}

- (void)handleTap:(UIButton *)sender {
    if (!tgextraVideoToVoiceEnabled()) return;
    id item = objc_getAssociatedObject(sender, kTGExtraVoicePreviewItemKey);
    BOOL enabled = tgextraToggleVoiceItem(item);
    tgextraStyleVoiceButton(sender, enabled);
    sender.accessibilityValue = [TGExtraLocalization localizedStringForKey:
        enabled ? @"VIDEO_TO_VOICE_ON_TOAST" : @"VIDEO_TO_VOICE_OFF_TOAST"];
    [sender.superview setNeedsLayout];
    tgextraDiag("v2v: preview toggle -> %d", enabled);

    TGExtraShowToast([TGExtraLocalization localizedStringForKey:
        enabled ? @"VIDEO_TO_VOICE_ON_TOAST" : @"VIDEO_TO_VOICE_OFF_TOAST"]);

    UIImpactFeedbackGenerator *haptic = [[UIImpactFeedbackGenerator alloc]
        initWithStyle:UIImpactFeedbackStyleMedium];
    [haptic impactOccurred];
}

- (void)handleRoundTap:(UIButton *)sender {
    if (!tgextraVideoToRoundEnabled()) return;
    id item = objc_getAssociatedObject(sender, kTGExtraVoicePreviewItemKey);
    BOOL enabled = tgextraToggleRoundItem(item);
    tgextraStyleRoundButton(sender, enabled);
    sender.accessibilityValue = [TGExtraLocalization localizedStringForKey:
        enabled ? @"VIDEO_TO_ROUND_ON_TOAST" : @"VIDEO_TO_ROUND_OFF_TOAST"];
    [sender.superview setNeedsLayout];
    TGExtraShowToast(sender.accessibilityValue);
    UIImpactFeedbackGenerator *haptic = [[UIImpactFeedbackGenerator alloc]
        initWithStyle:UIImpactFeedbackStyleMedium];
    [haptic impactOccurred];
}

@end

static UIView *tgextraFindSubviewByClassSubstring(UIView *root, NSString *needle, int depth) {
    if (!root || depth > 6) return nil;
    for (UIView *sub in root.subviews) {
        if ([NSStringFromClass([sub class]) containsString:needle]) return sub;
        UIView *found = tgextraFindSubviewByClassSubstring(sub, needle, depth + 1);
        if (found) return found;
    }
    return nil;
}

static CGRect tgextraVoiceButtonFrame(UIView *interfaceView) {
    CGFloat side = kTGExtraVoiceButtonSide;
    UIWindow *window = interfaceView.window;
    CGRect bounds = interfaceView.bounds;

    UIEdgeInsets safe = interfaceView.safeAreaInsets;
    if (safe.top < 1.0 && window) safe = window.safeAreaInsets;

    CGFloat x = bounds.size.width - safe.right - 8.0 - side;
    CGFloat y = safe.top + 5.0 + side + 8.0;

    UIView *check = tgextraFindSubviewByClassSubstring(interfaceView, @"CheckButton", 0);
    if (check && !check.hidden && check.bounds.size.height > 0) {
        CGRect frame = [interfaceView convertRect:check.bounds fromView:check];
        x = CGRectGetMidX(frame) - side / 2.0;
        y = CGRectGetMaxY(frame) + 8.0;
    }

    if (window) {
        CGPoint inWindow = [interfaceView convertPoint:CGPointMake(x, y) toView:window];
        CGFloat minY = window.safeAreaInsets.top + 5.0;
        if (inWindow.y < minY) y += (minY - inWindow.y);
    }

    x = MAX(safe.left + 8.0, MIN(x, bounds.size.width - safe.right - 8.0 - side));
    y = MAX(safe.top + 5.0, MIN(y, bounds.size.height - safe.bottom - 8.0 - side));

    return CGRectMake(x, y, side, side);
}

static void tgextraUpdateVoiceButton(UIView *interfaceView) {
    if (!interfaceView) return;

    BOOL isVideo = [objc_getAssociatedObject(interfaceView, kTGExtraItemIsVideoKey) boolValue];
    UIButton *button = (UIButton *)[interfaceView viewWithTag:kTGExtraVoiceButtonTag];
    UIButton *roundButton = (UIButton *)[interfaceView viewWithTag:kTGExtraRoundButtonTag];

    id item = objc_getAssociatedObject(interfaceView, kTGExtraVoicePreviewItemKey);
    id context = tgextraVoiceProperty(item, @"editingContext");
    NSString *identifier = tgextraVoiceItemIdentifier(item);
    if ((!tgextraVideoToVoiceEnabled() && !tgextraVideoToRoundEnabled()) || !isVideo || !context || !identifier) {
        button.hidden = YES;
        roundButton.hidden = YES;
        return;
    }

    if (!button && tgextraVideoToVoiceEnabled()) {
        button = [UIButton buttonWithType:UIButtonTypeSystem];
        button.tag = kTGExtraVoiceButtonTag;
        button.layer.cornerRadius = kTGExtraVoiceButtonSide / 2.0;
        button.clipsToBounds = YES;
        [button addTarget:[TGExtraVoiceToggleTarget shared]
                   action:@selector(handleTap:)
         forControlEvents:UIControlEventTouchUpInside];
        [interfaceView addSubview:button];
    }

    if (button) objc_setAssociatedObject(button, kTGExtraVoicePreviewItemKey, item,
                                         OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    BOOL enabled = [tgextraVoiceItems(context) containsObject:identifier];
    button.accessibilityLabel = [TGExtraLocalization localizedStringForKey:@"VIDEO_TO_VOICE_TITLE"];
    button.accessibilityValue = [TGExtraLocalization localizedStringForKey:
        enabled ? @"VIDEO_TO_VOICE_ON_TOAST" : @"VIDEO_TO_VOICE_OFF_TOAST"];
    button.hidden = !tgextraVideoToVoiceEnabled();
    button.selected = enabled;
    tgextraStyleVoiceButton(button, enabled);
    button.frame = tgextraVoiceButtonFrame(interfaceView);
    if (button) [interfaceView bringSubviewToFront:button];

    if (!roundButton && tgextraVideoToRoundEnabled()) {
        roundButton = [UIButton buttonWithType:UIButtonTypeSystem];
        roundButton.tag = kTGExtraRoundButtonTag;
        roundButton.layer.cornerRadius = kTGExtraVoiceButtonSide / 2.0;
        roundButton.clipsToBounds = YES;
        [roundButton addTarget:[TGExtraVoiceToggleTarget shared] action:@selector(handleRoundTap:)
             forControlEvents:UIControlEventTouchUpInside];
        [interfaceView addSubview:roundButton];
    }
    if (roundButton) objc_setAssociatedObject(roundButton, kTGExtraVoicePreviewItemKey, item,
                                              OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    BOOL roundEnabled = [tgextraRoundItems(context) containsObject:identifier];
    roundButton.accessibilityLabel = [TGExtraLocalization localizedStringForKey:@"VIDEO_TO_ROUND_TITLE"];
    roundButton.accessibilityValue = [TGExtraLocalization localizedStringForKey:
        roundEnabled ? @"VIDEO_TO_ROUND_ON_TOAST" : @"VIDEO_TO_ROUND_OFF_TOAST"];
    roundButton.selected = roundEnabled;
    roundButton.hidden = !tgextraVideoToRoundEnabled();
    tgextraStyleRoundButton(roundButton, roundEnabled);
    CGRect roundFrame = tgextraVoiceButtonFrame(interfaceView);
    if (tgextraVideoToVoiceEnabled()) roundFrame.origin.y += kTGExtraVoiceButtonSide + 8.0;
    roundButton.frame = roundFrame;
    if (roundButton) [interfaceView bringSubviewToFront:roundButton];

#if TGEXTRA_DIAG
    static CGRect lastFrame = {{0, 0}, {0, 0}};
    if (!CGRectEqualToRect(lastFrame, button.frame)) {
        lastFrame = button.frame;
        UIEdgeInsets viewSafe = interfaceView.safeAreaInsets;
        UIEdgeInsets winSafe = interfaceView.window.safeAreaInsets;
        tgextraDiag("v2v: button at %.0f,%.0f — viewSafeTop=%.0f windowSafeTop=%.0f",
                 button.frame.origin.x, button.frame.origin.y,
                 viewSafe.top, winSafe.top);
    }
#endif
}

%group TGExtraVoicePreview
%hook TGMediaPickerGalleryInterfaceView

- (void)itemFocused:(id)item itemView:(id)itemView {
    %orig;
    objc_setAssociatedObject(self, kTGExtraItemIsVideoKey, @(tgextraItemIsVideo(item)),
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(self, kTGExtraVoicePreviewItemKey, item,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    tgextraUpdateVoiceButton(self);
}

- (void)layoutSubviews {
    %orig;
    tgextraUpdateVoiceButton(self);
}

- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    for (NSNumber *tag in @[@(kTGExtraVoiceButtonTag), @(kTGExtraRoundButtonTag)]) {
        UIButton *button = (UIButton *)[self viewWithTag:tag.integerValue];
        if (button && !button.hidden && button.alpha > 0.01) {
            if ([button pointInside:[self convertPoint:point toView:button] withEvent:event]) {
                return button;
            }
        }
    }
    return %orig;
}

%end
%end

%ctor {
    Class preview = objc_getClass("TGMediaPickerGalleryInterfaceView");
    Method focus = class_getInstanceMethod(preview, @selector(itemFocused:itemView:));
    if (focus && method_getNumberOfArguments(focus) == 4 &&
        class_getInstanceMethod(preview, @selector(layoutSubviews)) &&
        class_getInstanceMethod(preview, @selector(hitTest:withEvent:))) {
        %init(TGExtraVoicePreview);
        TGExtraRecordHookStatus(@"Voice preview", @"installed");
    } else {
        TGExtraRecordHookStatus(@"Voice preview", @"unavailable: gallery interface");
    }
}
