#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <objc/runtime.h>
#import "Constants.h"
#import "PaidMedia.h"

@interface NSObject (TGExtraCaptureDisplayNode)
- (UIView *)view;
@end

static char paidCaptureRootKey, originalImageCaptureKey, originalVideoCaptureKey;
// All UIKit manipulation and host capture changes below run on the main thread.
static BOOL applyingCaptureChange;

static BOOL paidLayerHasCaptureRoot(CALayer *layer) {
    if (!NSThread.isMainThread) return NO;
    for (CALayer *current = layer; current; current = current.superlayer) {
        if ([objc_getAssociatedObject(current, &paidCaptureRootKey) boolValue]) return YES;
    }
    return NO;
}

static BOOL paidLayerAllowsCapture(CALayer *layer) {
    return paidLayerHasCaptureRoot(layer) &&
        [NSUserDefaults.standardUserDefaults boolForKey:kDisableForwardRestriction];
}

static UIView *captureCanvas(UITextField *field) {
    for (UIView *view in field.subviews) {
        if ([NSStringFromClass(view.class) containsString:@"TextLayoutCanvasView"]) return view;
    }
    return nil;
}

// Same UIKit path as Telegram's UIKitRuntimeUtils.setLayerDisableScreenshots.
// Rebinding the secure canvas also updates the render-server protection state.
static void setImageCaptureProtected(CALayer *layer, BOOL captureProtected) {
    static UITextField *field;
    static UIView *canvas;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        field = [UITextField new];
        canvas = captureCanvas(field);
    });
    if (!canvas) return;
    CALayer *previous = canvas.layer;
    BOOL wasApplying = applyingCaptureChange;
    applyingCaptureChange = YES;
    @try {
        [canvas setValue:layer forKey:@"layer"];
        field.secureTextEntry = !captureProtected;
        field.secureTextEntry = captureProtected;
    } @finally {
        [canvas setValue:previous forKey:@"layer"];
        applyingCaptureChange = wasApplying;
    }
}

static void updateCaptureLayers(CALayer *layer, BOOL allow) {
    if (allow) {
        // These are CoreAnimation's two capture bits. Reading the mask avoids
        // repeatedly toggling every unprotected layer during gallery layout.
        NSNumber *mask = nil;
        @try { mask = [layer valueForKey:@"disableUpdateMask"]; }
        @catch (NSException *exception) {}
        if ([mask respondsToSelector:@selector(unsignedIntValue)] && (mask.unsignedIntValue & 0x12)) {
            objc_setAssociatedObject(layer, &originalImageCaptureKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            setImageCaptureProtected(layer, NO);
        }
    } else {
        NSNumber *original = objc_getAssociatedObject(layer, &originalImageCaptureKey);
        if (original) setImageCaptureProtected(layer, original.boolValue);
        objc_setAssociatedObject(layer, &originalImageCaptureKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    if ([layer isKindOfClass:AVSampleBufferDisplayLayer.class]) {
        AVSampleBufferDisplayLayer *video = (id)layer;
        NSNumber *original = objc_getAssociatedObject(layer, &originalVideoCaptureKey);
        if (allow && video.preventsCapture) {
            objc_setAssociatedObject(layer, &originalVideoCaptureKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            BOOL wasApplying = applyingCaptureChange;
            applyingCaptureChange = YES;
            video.preventsCapture = NO;
            applyingCaptureChange = wasApplying;
        } else if (!allow && original) {
            video.preventsCapture = original.boolValue;
            objc_setAssociatedObject(layer, &originalVideoCaptureKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
    }
    for (CALayer *child in layer.sublayers) updateCaptureLayers(child, allow);
    if (layer.mask) updateCaptureLayers(layer.mask, allow);
}

static void updateMovedCaptureLayers(CALayer *layer, BOOL hadCaptureRoot) {
    if (applyingCaptureChange || !NSThread.isMainThread) return;
    BOOL allow = paidLayerAllowsCapture(layer);
    if (allow || hadCaptureRoot) updateCaptureLayers(layer, allow);
}

void TGExtraUpdatePaidMediaCapture(id node) {
    NSString *name = NSStringFromClass([node class]);
    if (![name hasSuffix:@".ChatImageGalleryItemNode"] &&
        ![name hasSuffix:@".UniversalVideoGalleryItemNode"]) return;
    if (!NSThread.isMainThread || ![node respondsToSelector:@selector(view)]) return;
    CALayer *root = [node view].layer;
    BOOL wasAllowed = [objc_getAssociatedObject(root, &paidCaptureRootKey) boolValue];
    id footer = [TGExtraPaidMediaFile footerNodeFromItem:node];
    BOOL allow = [NSUserDefaults.standardUserDefaults boolForKey:kDisableForwardRestriction] &&
        footer && [TGExtraPaidMediaFile fileFromFooterNode:footer] != nil;
    objc_setAssociatedObject(root, &paidCaptureRootKey, allow ? @YES : nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if (allow || wasAllowed) updateCaptureLayers(root, allow);
}

%hook UITextField
- (void)setSecureTextEntry:(BOOL)value {
    // Telegram temporarily assigns an image layer to its secure text canvas.
    // Keep later redraws from re-enabling protection inside a paid gallery item.
    if (!applyingCaptureChange && NSThread.isMainThread &&
        [NSUserDefaults.standardUserDefaults boolForKey:kDisableForwardRestriction]) {
        CALayer *layer = captureCanvas((UITextField *)self).layer;
        if (paidLayerAllowsCapture(layer)) {
            objc_setAssociatedObject(layer, &originalImageCaptureKey, @(value), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            value = NO;
        }
    }
    %orig(value);
}
%end

%hook AVSampleBufferDisplayLayer
- (void)setPreventsCapture:(BOOL)value {
    if (!applyingCaptureChange && paidLayerAllowsCapture((CALayer *)self)) {
        objc_setAssociatedObject(self, &originalVideoCaptureKey, @(value), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        value = NO;
    }
    %orig(value);
}
%end

%hook CALayer
- (void)addSublayer:(CALayer *)layer {
    BOOL hadCaptureRoot = paidLayerHasCaptureRoot(layer);
    %orig;
    // Telegram shares video content between the gallery and chat. Apply the
    // destination policy immediately, including on implicit reparenting.
    updateMovedCaptureLayers(layer, hadCaptureRoot);
}
- (void)insertSublayer:(CALayer *)layer atIndex:(unsigned int)index {
    BOOL hadCaptureRoot = paidLayerHasCaptureRoot(layer);
    %orig;
    updateMovedCaptureLayers(layer, hadCaptureRoot);
}
- (void)insertSublayer:(CALayer *)layer below:(CALayer *)sibling {
    BOOL hadCaptureRoot = paidLayerHasCaptureRoot(layer);
    %orig;
    updateMovedCaptureLayers(layer, hadCaptureRoot);
}
- (void)insertSublayer:(CALayer *)layer above:(CALayer *)sibling {
    BOOL hadCaptureRoot = paidLayerHasCaptureRoot(layer);
    %orig;
    updateMovedCaptureLayers(layer, hadCaptureRoot);
}
- (void)replaceSublayer:(CALayer *)oldLayer with:(CALayer *)layer {
    BOOL oldHadCaptureRoot = paidLayerHasCaptureRoot(oldLayer);
    BOOL hadCaptureRoot = paidLayerHasCaptureRoot(layer);
    %orig;
    updateMovedCaptureLayers(oldLayer, oldHadCaptureRoot);
    updateMovedCaptureLayers(layer, hadCaptureRoot);
}
- (void)removeFromSuperlayer {
    BOOL hadCaptureRoot = paidLayerHasCaptureRoot((CALayer *)self);
    %orig;
    updateMovedCaptureLayers((CALayer *)self, hadCaptureRoot);
}
- (void)setSublayers:(NSArray<CALayer *> *)layers {
    if (applyingCaptureChange || !NSThread.isMainThread) {
        %orig;
        return;
    }
    NSArray<CALayer *> *previous = ((CALayer *)self).sublayers;
    BOOL hadCaptureRoot = paidLayerHasCaptureRoot((CALayer *)self);
    NSMutableIndexSet *previousRoots = [NSMutableIndexSet indexSet];
    [layers enumerateObjectsUsingBlock:^(CALayer *layer, NSUInteger index, BOOL *stop) {
        if (paidLayerHasCaptureRoot(layer)) [previousRoots addIndex:index];
    }];
    %orig;
    for (CALayer *layer in previous) {
        if (layer.superlayer != self) updateMovedCaptureLayers(layer, hadCaptureRoot);
    }
    [layers enumerateObjectsUsingBlock:^(CALayer *layer, NSUInteger index, BOOL *stop) {
        updateMovedCaptureLayers(layer, [previousRoots containsIndex:index]);
    }];
}
%end
