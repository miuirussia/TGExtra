#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import <objc/runtime.h>
#import "Constants.h"

@interface TGExtraLottieRenderer : NSObject
- (instancetype)initWithData:(NSData *)data fitzModifier:(int32_t)fitzModifier
          colorReplacements:(NSDictionary *)colorReplacements;
@end

static Class TGExtraTLottieClass;
typedef id (*TGExtraLottieInitializer)(id __attribute__((ns_consumed)), SEL,
    NSData *, int32_t, NSDictionary *, NSString *) __attribute__((ns_returns_retained));
static TGExtraLottieInitializer TGExtraOriginalLottieInit;

static BOOL TGExtraLottieMethodMatches(Class cls, SEL selector, const char *result,
                                      NSArray<NSString *> *arguments) {
    Method method = class_getInstanceMethod(cls, selector);
    if (!method) return NO;
    NSMethodSignature *signature = [NSMethodSignature signatureWithObjCTypes:method_getTypeEncoding(method)];
    if (strcmp(signature.methodReturnType, result) != 0 ||
        signature.numberOfArguments != arguments.count + 2) return NO;
    for (NSUInteger i = 0; i < arguments.count; i++) {
        if (strcmp([signature getArgumentTypeAtIndex:i + 2], arguments[i].UTF8String) != 0) return NO;
    }
    return YES;
}

static BOOL TGExtraLottieRendererMatches(Class cls, SEL initializer, NSArray<NSString *> *arguments) {
    return TGExtraLottieMethodMatches(cls, initializer, @encode(id), arguments) &&
        TGExtraLottieMethodMatches(cls, @selector(frameCount), @encode(int32_t), @[]) &&
        TGExtraLottieMethodMatches(cls, @selector(frameRate), @encode(int32_t), @[]) &&
        TGExtraLottieMethodMatches(cls, @selector(duration), @encode(double), @[]) &&
        TGExtraLottieMethodMatches(cls, @selector(dimensions), @encode(CGSize), @[]) &&
        TGExtraLottieMethodMatches(cls, @selector(renderFrameWithIndex:into:width:height:bytesPerRow:),
            @encode(void), @[@(@encode(int32_t)), @(@encode(uint8_t *)),
                            @(@encode(int32_t)), @(@encode(int32_t)), @(@encode(int32_t))]);
}

static id TGExtraLottieInit(id self __attribute__((ns_consumed)), SEL selector,
    NSData *data, int32_t fitzModifier, NSDictionary *colorReplacements,
    NSString *cacheKey) __attribute__((ns_returns_retained)) {
    if ([NSUserDefaults.standardUserDefaults boolForKey:kForceTLottie]) {
        return [[TGExtraTLottieClass alloc] initWithData:data fitzModifier:fitzModifier
                                     colorReplacements:colorReplacements];
    }
    return TGExtraOriginalLottieInit(self, selector, data, fitzModifier, colorReplacements, cacheKey);
}

__attribute__((constructor)) static void TGExtraInstallForceTLottie(void) {
    @autoreleasepool {
        Class rlottie = NSClassFromString(@"RLottieInstance");
        Class tlottie = NSClassFromString(@"TLottieAnimation");
        NSArray *arguments = @[@(@encode(id)), @(@encode(int32_t)), @(@encode(id))];
        if (TGExtraLottieRendererMatches(rlottie, @selector(initWithData:fitzModifier:colorReplacements:cacheKey:),
                [arguments arrayByAddingObject:@(@encode(id))]) &&
            TGExtraLottieRendererMatches(tlottie, @selector(initWithData:fitzModifier:colorReplacements:), arguments)) {
            TGExtraTLottieClass = tlottie;
            Method initializer = class_getInstanceMethod(rlottie,
                @selector(initWithData:fitzModifier:colorReplacements:cacheKey:));
            TGExtraOriginalLottieInit = (TGExtraLottieInitializer)method_setImplementation(initializer, (IMP)TGExtraLottieInit);
        }
    }
}
