#import "RecordingInputLayout.h"
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#import <math.h>

@interface TGExtraRecordingControls : NSObject
+ (NSDictionary *)fromNode:(id)node;
+ (NSDictionary *)inputLayoutFromNode:(id)node;
+ (NSArray *)backgroundPartsFromView:(id)view;
@end

@interface NSObject (TGExtraRecordingLayoutNode)
- (UIView *)view;
@end

@interface TGExtraRecordingInputOwner : NSObject
@property (nonatomic, weak) id node;
@end
@implementation TGExtraRecordingInputOwner
@end

static char TGExtraRecordingInputOwnerKey;

static UIView *TGExtraRecordingView(id value) {
    if ([value isKindOfClass:UIView.class]) return value;
    return [value respondsToSelector:@selector(view)] ? [value view] : nil;
}

void TGExtraBindRecordingInput(id node) {
    NSDictionary *layout = [TGExtraRecordingControls inputLayoutFromNode:node];
    UIView *background = TGExtraRecordingView(layout[@"textInputContainerBackgroundView"]);
    if (!background) return;
    TGExtraRecordingInputOwner *owner = [TGExtraRecordingInputOwner new];
    owner.node = node;
    objc_setAssociatedObject(background, &TGExtraRecordingInputOwnerKey, owner, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [background setNeedsLayout];
}

static BOOL TGExtraRecordingViewIsVisible(UIView *view) {
    return view && !view.hidden && view.alpha > 0.01 &&
        fabs(view.transform.a) > 0.01 && fabs(view.transform.d) > 0.01;
}

// Capture all geometry before changing a parent: UIKit may autoresize children
// synchronously, and applying the delta to those new sizes would grow them twice.
static void TGExtraRecordingCapture(id value, CGFloat delta, BOOL widen,
                                    NSMutableDictionary<id, NSDictionary *> *changes) {
    UIView *view = TGExtraRecordingView(value);
    CALayer *layer = view.layer;
    if (!layer && [value isKindOfClass:CALayer.class]) layer = value;
    if (!layer) return;
    NSValue *key = [NSValue valueWithNonretainedObject:layer];
    if (changes[key]) return;
    CGRect bounds = layer.bounds;
    CGPoint position = layer.position;
    if (widen) bounds.size.width += delta;
    position.x += widen ? delta * layer.anchorPoint.x : delta;
    changes[key] = @{@"target": view ?: layer, @"bounds": [NSValue valueWithCGRect:bounds],
                     @"position": [NSValue valueWithCGPoint:position]};
}

static BOOL TGExtraRecordingCaptureEditor(UIView *view, CGFloat delta, NSMutableDictionary *changes) {
    BOOL hasEditor = [view isKindOfClass:UITextView.class];
    if (!hasEditor) {
        for (UIView *child in view.subviews) {
            if (TGExtraRecordingCaptureEditor(child, delta, changes)) hasEditor = YES;
        }
    }
    if (hasEditor) TGExtraRecordingCapture(view, delta, YES, changes);
    return hasEditor;
}

void TGExtraLayoutRecordingInput(UIView *background) {
    TGExtraRecordingInputOwner *owner = objc_getAssociatedObject(background, &TGExtraRecordingInputOwnerKey);
    id node = owner.node;
    if (!node) return;
    NSDictionary *layout = [TGExtraRecordingControls inputLayoutFromNode:node];
    if ([layout[@"isUpdating"] boolValue]) {
        [background setNeedsLayout];
        return;
    }
    if ([layout[@"hasOtherRightAction"] boolValue]) return;
    UIView *media = TGExtraRecordingView(layout[@"mediaActionButtons"]);
    UIView *panel = TGExtraRecordingView(node);
    NSNumber *rightInset = layout[@"rightInset"];
    if (!panel || !media.superview || !background.superview || !rightInset) return;
    NSDictionary *mediaControls = [TGExtraRecordingControls fromNode:layout[@"mediaActionButtons"]];
    UIView *expand = TGExtraRecordingView(mediaControls[@"expandMediaInputButtonBackgroundView"]
        ?: mediaControls[@"expandMediaInputButton"]);
    if (TGExtraRecordingViewIsVisible(expand)) return;
    id sendNode = layout[@"sendActionButtons"];
    NSDictionary *sendControls = sendNode ? [TGExtraRecordingControls fromNode:sendNode] : nil;
    UIView *send = TGExtraRecordingView(sendNode);
    if (TGExtraRecordingViewIsVisible(send) &&
        TGExtraRecordingViewIsVisible(TGExtraRecordingView(sendControls[@"sendContainerNode"]))) return;

    CGRect mediaFrame = [panel convertRect:media.bounds fromView:media];
    CGRect inputFrame = [panel convertRect:background.bounds fromView:background];
    // Text, forwards, drafts and editing move the media slot outside the panel.
    // Using the slot's actual trailing edge preserves landscape/tablet safe insets.
    CGFloat delta = CGRectGetMaxX(mediaFrame) - CGRectGetMaxX(inputFrame);
    CGFloat spacing = CGRectGetMinX(mediaFrame) - CGRectGetMaxX(inputFrame);
    if (!isfinite(delta) || delta <= 0.5 || spacing < -0.5 || spacing > mediaFrame.size.width ||
        CGRectGetMaxX(mediaFrame) > CGRectGetMaxX(panel.bounds) - rightInset.doubleValue + 0.5 ||
        mediaFrame.size.width <= 0.0 || inputFrame.size.width <= 0.0) return;

    NSMutableDictionary *changes = [NSMutableDictionary new];
    TGExtraRecordingCapture(background, delta, YES, changes);
    for (id part in [TGExtraRecordingControls backgroundPartsFromView:background]) {
        TGExtraRecordingCapture(part, delta, YES, changes);
        if ([part isKindOfClass:UIVisualEffectView.class]) {
            TGExtraRecordingCapture(((UIVisualEffectView *)part).contentView, delta, YES, changes);
        }
    }
    for (NSString *key in @[@"textInputBackgroundNode", @"accessoryPanelContainer", @"textInputNodeClippingContainer"]) {
        TGExtraRecordingCapture(layout[key], delta, YES, changes);
    }
    // The field is empty here; keep its editor and touch region as wide as its
    // clipping container. Native layout takes over as soon as content is entered.
    UIView *clip = TGExtraRecordingView(layout[@"textInputNodeClippingContainer"]);
    for (UIView *editor in clip.subviews) {
        TGExtraRecordingCaptureEditor(editor, delta, changes);
        TGExtraRecordingCapture(editor, delta, YES, changes);
    }
    for (id accessory in layout[@"accessories"]) TGExtraRecordingCapture(accessory, delta, NO, changes);

    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    // Parents first, then their captured children, overriding autoresizing.
    NSArray *ordered = [changes.allValues sortedArrayUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        id at = a[@"target"], bt = b[@"target"];
        CALayer *al = [at isKindOfClass:UIView.class] ? [at layer] : at;
        CALayer *bl = [bt isKindOfClass:UIView.class] ? [bt layer] : bt;
        NSUInteger ad = 0, bd = 0;
        for (; al.superlayer; al = al.superlayer) ad++;
        for (; bl.superlayer; bl = bl.superlayer) bd++;
        return ad < bd ? NSOrderedAscending : ad > bd ? NSOrderedDescending : NSOrderedSame;
    }];
    for (NSDictionary *change in ordered) {
        id target = change[@"target"];
        UIView *view = TGExtraRecordingView(target);
        CALayer *layer = view ? view.layer : target;
        for (NSString *key in @[@"bounds", @"bounds.size", @"bounds.size.width", @"position", @"position.x"]) {
            [layer removeAnimationForKey:key];
        }
        CGRect bounds = [change[@"bounds"] CGRectValue];
        CGPoint position = [change[@"position"] CGPointValue];
        if (view) {
            view.bounds = bounds;
            view.center = position;
        } else {
            layer.bounds = bounds;
            layer.position = position;
        }
    }
    [CATransaction commit];
}
