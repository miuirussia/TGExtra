#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <objc/runtime.h>
#import "Constants.h"
#import "PaidMedia.h"

@interface NSObject (TGExtraCaptureDisplayNode)
- (UIView *)view;
@end

@interface UIView (TGExtraCaptureNodeView)
- (id)asyncdisplaykit_node;
@end

@interface TGExtraSecretChatPolicy : NSObject
+ (BOOL)isSecretGalleryItem:(id)node;
@end

static char paidCaptureRootKey, secretCaptureRootKey, originalImageCaptureKey, originalVideoCaptureKey;
static char canvasOwnLayerKey, requestedImageCaptureKey;
static BOOL applyingCaptureChange;
static NSUInteger clearedImageLayers, clearedVideoLayers;

static void recordCaptureStatus(NSString *key, NSString *value) {
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    if (![[defaults stringForKey:key] isEqualToString:value]) [defaults setObject:value forKey:key];
}

static BOOL layerHasCaptureRoot(CALayer *layer) {
    if (!NSThread.isMainThread) return NO;
    for (CALayer *current = layer; current; current = current.superlayer) {
        if ([objc_getAssociatedObject(current, &paidCaptureRootKey) boolValue] ||
            [objc_getAssociatedObject(current, &secretCaptureRootKey) boolValue]) return YES;
    }
    return NO;
}

static BOOL layerAllowsCapture(CALayer *layer) {
    if (!NSThread.isMainThread) return NO;
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    for (CALayer *current = layer; current; current = current.superlayer) {
        if ([objc_getAssociatedObject(current, &paidCaptureRootKey) boolValue] &&
            [defaults boolForKey:kDisableForwardRestriction]) return YES;
        if ([objc_getAssociatedObject(current, &secretCaptureRootKey) boolValue] &&
            [defaults boolForKey:kDisableScreenshotNotification]) return YES;
    }
    return NO;
}

static UIView *captureCanvas(UITextField *field) {
    for (UIView *view in field.subviews) {
        if ([NSStringFromClass(view.class) containsString:@"TextLayoutCanvasView"]) return view;
    }
    return nil;
}

static BOOL setImageCaptureProtected(CALayer *layer, BOOL captureProtected) {
    static UITextField *field;
    static UIView *canvas;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        field = [UITextField new];
        canvas = captureCanvas(field);
        if (canvas) recordCaptureStatus(@"TGExtraCaptureCanvasStatus", @"Secure canvas ready");
    });
    if (!canvas) {
        recordCaptureStatus(@"TGExtraCaptureCanvasStatus", @"Secure text canvas unavailable");
        return NO;
    }
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
    return YES;
}

static void updateCaptureLayers(CALayer *layer, BOOL allow) {
    if (allow) {
        NSNumber *requested = objc_getAssociatedObject(layer, &requestedImageCaptureKey);
        NSNumber *original = objc_getAssociatedObject(layer, &originalImageCaptureKey);
        NSNumber *mask = nil;
        if (!requested) {
            @try { mask = [layer valueForKey:@"disableUpdateMask"]; }
            @catch (NSException *exception) {}
        }
        BOOL isProtected = requested ? requested.boolValue :
            ([mask respondsToSelector:@selector(unsignedIntValue)] && (mask.unsignedIntValue & 0x12));
        if (isProtected && !original) {
            if (setImageCaptureProtected(layer, NO)) {
                objc_setAssociatedObject(layer, &originalImageCaptureKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                clearedImageLayers++;
            }
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
            clearedVideoLayers++;
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
    BOOL allow = layerAllowsCapture(layer);
    if (allow || hadCaptureRoot) updateCaptureLayers(layer, allow);
}

static void updateGalleryCapture(id node) {
    NSString *name = NSStringFromClass([node class]);
    if (![name hasSuffix:@".ChatImageGalleryItemNode"] &&
        ![name hasSuffix:@".UniversalVideoGalleryItemNode"]) return;
    if (!NSThread.isMainThread || ![node respondsToSelector:@selector(view)]) return;
    [TGExtraPaidMediaFile bindGalleryItem:node];
    CALayer *root = [node view].layer;
    BOOL wasAllowed = layerHasCaptureRoot(root);
    BOOL unlocked = [TGExtraPaidMediaFile isUnlockedPaidItem:node];
    BOOL paid = [NSUserDefaults.standardUserDefaults boolForKey:kDisableForwardRestriction] && unlocked;
    BOOL secret = [TGExtraSecretChatPolicy isSecretGalleryItem:node] &&
        [NSUserDefaults.standardUserDefaults boolForKey:kDisableScreenshotNotification];
    BOOL allow = paid || secret;
    objc_setAssociatedObject(root, &paidCaptureRootKey, paid ? @YES : nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(root, &secretCaptureRootKey, secret ? @YES : nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if (allow || wasAllowed) updateCaptureLayers(root, allow);
    if (secret || wasAllowed) recordCaptureStatus(@"TGExtraSecretCaptureStatus", secret ? @"Secret gallery capture enabled" : @"Secret gallery capture inactive");
    NSString *reason = allow ? @"capture bypass enabled" :
        (!unlocked ? @"inactive: item not recognized as unlocked paid media" : @"inactive: saving protected content is off");
    recordCaptureStatus(@"TGExtraPaidCaptureStatus", [NSString stringWithFormat:
        @"%@ unlocked=%d allow=%d; cleared images=%lu videos=%lu; %@", name, unlocked, allow,
        (unsigned long)clearedImageLayers, (unsigned long)clearedVideoLayers, reason]);
}

%group TGExtraGalleryCaptureViews
%hook TGExtraGalleryCaptureView
- (void)layoutSubviews {
    %orig;
    if ([(UIView *)self respondsToSelector:@selector(asyncdisplaykit_node)]) {
        updateGalleryCapture([(UIView *)self asyncdisplaykit_node]);
    }
}
- (void)didMoveToWindow {
    %orig;
    if ([(UIView *)self respondsToSelector:@selector(asyncdisplaykit_node)]) {
        updateGalleryCapture([(UIView *)self asyncdisplaykit_node]);
    }
}
%end
%end

%hook UIView
- (void)setValue:(id)value forKey:(NSString *)key {
    if (!applyingCaptureChange && NSThread.isMainThread && [key isEqualToString:@"layer"] &&
        [NSStringFromClass(self.class) containsString:@"TextLayoutCanvasView"] &&
        !objc_getAssociatedObject(self, &canvasOwnLayerKey)) {
        objc_setAssociatedObject(self, &canvasOwnLayerKey, ((UIView *)self).layer, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    %orig(value, key);
}
%end

%hook UITextField
- (void)setSecureTextEntry:(BOOL)value {
    if (!applyingCaptureChange && NSThread.isMainThread) {
        UIView *canvas = captureCanvas((UITextField *)self);
        CALayer *ownLayer = objc_getAssociatedObject(canvas, &canvasOwnLayerKey);
        CALayer *layer = canvas.layer;
        if (ownLayer && layer != ownLayer) {
            objc_setAssociatedObject(layer, &requestedImageCaptureKey, @(value), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            if (layerAllowsCapture(layer)) {
                objc_setAssociatedObject(layer, &originalImageCaptureKey, @(value), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                value = NO;
            }
        }
    }
    %orig(value);
}
%end

%hook AVSampleBufferDisplayLayer
- (void)setPreventsCapture:(BOOL)value {
    if (!applyingCaptureChange && layerAllowsCapture((CALayer *)self)) {
        objc_setAssociatedObject(self, &originalVideoCaptureKey, @(value), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        value = NO;
    }
    %orig(value);
}
%end

%hook CALayer
- (void)addSublayer:(CALayer *)layer {
    BOOL hadCaptureRoot = layerHasCaptureRoot(layer);
    %orig;
    updateMovedCaptureLayers(layer, hadCaptureRoot);
}
- (void)insertSublayer:(CALayer *)layer atIndex:(unsigned int)index {
    BOOL hadCaptureRoot = layerHasCaptureRoot(layer);
    %orig;
    updateMovedCaptureLayers(layer, hadCaptureRoot);
}
- (void)insertSublayer:(CALayer *)layer below:(CALayer *)sibling {
    BOOL hadCaptureRoot = layerHasCaptureRoot(layer);
    %orig;
    updateMovedCaptureLayers(layer, hadCaptureRoot);
}
- (void)insertSublayer:(CALayer *)layer above:(CALayer *)sibling {
    BOOL hadCaptureRoot = layerHasCaptureRoot(layer);
    %orig;
    updateMovedCaptureLayers(layer, hadCaptureRoot);
}
- (void)replaceSublayer:(CALayer *)oldLayer with:(CALayer *)layer {
    BOOL oldHadCaptureRoot = layerHasCaptureRoot(oldLayer);
    BOOL hadCaptureRoot = layerHasCaptureRoot(layer);
    %orig;
    updateMovedCaptureLayers(oldLayer, oldHadCaptureRoot);
    updateMovedCaptureLayers(layer, hadCaptureRoot);
}
- (void)removeFromSuperlayer {
    BOOL hadCaptureRoot = layerHasCaptureRoot((CALayer *)self);
    %orig;
    updateMovedCaptureLayers((CALayer *)self, hadCaptureRoot);
}
- (void)setSublayers:(NSArray<CALayer *> *)layers {
    if (applyingCaptureChange || !NSThread.isMainThread) {
        %orig;
        return;
    }
    NSArray<CALayer *> *previous = ((CALayer *)self).sublayers;
    BOOL hadCaptureRoot = layerHasCaptureRoot((CALayer *)self);
    NSMutableIndexSet *previousRoots = [NSMutableIndexSet indexSet];
    [layers enumerateObjectsUsingBlock:^(CALayer *layer, NSUInteger index, BOOL *stop) {
        if (layerHasCaptureRoot(layer)) [previousRoots addIndex:index];
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

__attribute__((constructor)) static void TGExtraInstallGalleryCaptureViews(void) {
    %init;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC / 2), dispatch_get_main_queue(), ^{
        Class view = NSClassFromString(@"Display.UITracingLayerView");
        if (class_getInstanceMethod(view, @selector(asyncdisplaykit_node)) &&
            class_getInstanceMethod(view, @selector(layoutSubviews)) &&
            class_getInstanceMethod(view, @selector(didMoveToWindow))) {
            %init(TGExtraGalleryCaptureViews, TGExtraGalleryCaptureView = view);
            recordCaptureStatus(@"TGExtraCaptureHookStatus", @"Gallery capture hook installed (secure-canvas ledger)");
        } else {
            recordCaptureStatus(@"TGExtraCaptureHookStatus", @"Gallery capture view or node accessor unavailable");
        }
    });
}
