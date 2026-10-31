#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <objc/runtime.h>
@interface TestDefaults : NSUserDefaults
@property NSMutableDictionary *values;
@end
@implementation TestDefaults
- (instancetype)init { if ((self = [super init])) self.values = [NSMutableDictionary new]; return self; }
- (BOOL)boolForKey:(NSString *)key { return [self.values[key] boolValue]; }
- (NSString *)stringForKey:(NSString *)key { return self.values[key]; }
- (void)setObject:(id)value forKey:(NSString *)key { self.values[key] = value; }
@end
static BOOL paidItem = YES, secretItem;
@interface TGExtraPaidMediaFile : NSObject
+ (void)bindGalleryItem:(id)item;
+ (BOOL)isUnlockedPaidItem:(id)item;
@end
@implementation TGExtraPaidMediaFile
+ (void)bindGalleryItem:(id)item {}
+ (BOOL)isUnlockedPaidItem:(id)item { return paidItem; }
@end
@interface TGExtraSecretChatPolicy : NSObject
+ (BOOL)isSecretGalleryItem:(id)item;
@end
@implementation TGExtraSecretChatPolicy
+ (BOOL)isSecretGalleryItem:(id)item { return secretItem; }
@end
static char nodeKey;
@interface UIView (Node)
- (id)asyncdisplaykit_node;
@end
@implementation UIView (Node)
- (id)asyncdisplaykit_node { return objc_getAssociatedObject(self, &nodeKey); }
@end
@interface TestNode : NSObject
@property UIView *view;
@end
@implementation TestNode @end
int main(void) {
    @autoreleasepool {
        TestDefaults *defaults = [TestDefaults new];
        Method getter = class_getClassMethod(NSUserDefaults.class, @selector(standardUserDefaults));
        method_setImplementation(getter, imp_implementationWithBlock(^id(id cls) { return defaults; }));
        [defaults setObject:@YES forKey:@"disableForwardRestriction"];
        Class galleryView = objc_allocateClassPair(UIView.class, "Display.UITracingLayerView", 0);
        objc_registerClassPair(galleryView);
        Class nodeClass = objc_allocateClassPair(TestNode.class, "GalleryUI.ChatImageGalleryItemNode", 0);
        objc_registerClassPair(nodeClass);
        TestNode *node = [nodeClass new];
        node.view = [galleryView new];
        objc_setAssociatedObject(node.view, &nodeKey, node, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [[NSRunLoop mainRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.7]];

        UITextField *field = [UITextField new];
        UIView *canvas = nil;
        for (UIView *view in field.subviews) {
            if ([NSStringFromClass(view.class) containsString:@"TextLayoutCanvasView"]) canvas = view;
        }
        NSCAssert(canvas, @"UIKit canvas exists");
        CALayer *own = canvas.layer;
        CALayer *image = [CALayer new];
        [canvas setValue:image forKey:@"layer"];
        field.secureTextEntry = NO;
        field.secureTextEntry = YES;
        [canvas setValue:own forKey:@"layer"];
        NSLog(@"Initial mask %@", [image valueForKey:@"disableUpdateMask"]);
        [node.view.layer addSublayer:image];
        [node.view layoutSubviews];
        NSString *status = [defaults stringForKey:@"TGExtraPaidCaptureStatus"];
        NSLog(@"%@", status);
        NSCAssert([status containsString:@"cleared images=1"],
                  @"Real UIKit capture protection was recognized without mask readback");

        [canvas setValue:image forKey:@"layer"];
        field.secureTextEntry = NO;
        field.secureTextEntry = YES;
        [canvas setValue:own forKey:@"layer"];
        NSCAssert(!field.secureTextEntry, @"Native reassertion stays disabled in paid gallery");
        UITextField *password = [UITextField new];
        password.secureTextEntry = YES;
        NSCAssert(password.secureTextEntry, @"Unrelated secure input preserved");
        AVSampleBufferDisplayLayer *video = [AVSampleBufferDisplayLayer new];
        video.preventsCapture = YES;
        [node.view.layer addSublayer:video];
        NSCAssert(!video.preventsCapture, @"Actual sample-buffer capture flag cleared");
        [defaults setObject:@NO forKey:@"disableForwardRestriction"];
        [node.view layoutSubviews];
        NSCAssert(video.preventsCapture, @"Paid capture restores the video flag");
        paidItem = NO;
        secretItem = YES;
        [defaults setObject:@YES forKey:@"TGExtraDisableScreenshotNotification"];
        [node.view layoutSubviews];
        NSCAssert(!video.preventsCapture, @"Secret screenshot setting independently clears video protection");
        [canvas setValue:image forKey:@"layer"];
        field.secureTextEntry = YES;
        [canvas setValue:own forKey:@"layer"];
        NSCAssert(!field.secureTextEntry, @"Secret gallery redraw stays capturable in real UIKit");
        [defaults setObject:@NO forKey:@"TGExtraDisableScreenshotNotification"];
        [node.view layoutSubviews];
        NSCAssert(video.preventsCapture && password.secureTextEntry, @"Secret capture restores protection and preserves passwords");
        puts("PASS real UIKit production hooks: opaque mask, secure canvas, gallery lifecycle, video layer and password fields");
    }
    return 0;
}
