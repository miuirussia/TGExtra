#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#include <string.h>

static inline BOOL TGExtraMethodMatches(Method method, const char *result,
                                       NSArray<NSString *> *arguments) {
    if (!method) return NO;
    NSMethodSignature *signature = [NSMethodSignature signatureWithObjCTypes:method_getTypeEncoding(method)];
    if (strcmp(signature.methodReturnType, result) != 0 ||
        signature.numberOfArguments != arguments.count + 2) return NO;
    for (NSUInteger i = 0; i < arguments.count; i++) {
        if (strcmp([signature getArgumentTypeAtIndex:i + 2], arguments[i].UTF8String) != 0) return NO;
    }
    return YES;
}

// Process-local state: never report a hook installed by a previous app version.
static inline NSDictionary<NSString *, NSString *> *TGExtraHookStatuses(void) {
    id owner = NSProcessInfo.processInfo;
    @synchronized(owner) {
        return [objc_getAssociatedObject(owner, sel_registerName("TGExtra.compatibility.hooks")) copy] ?: @{};
    }
}

static inline void TGExtraRecordHookStatus(NSString *name, NSString *status) {
    id owner = NSProcessInfo.processInfo;
    @synchronized(owner) {
        SEL key = sel_registerName("TGExtra.compatibility.hooks");
        NSMutableDictionary *entries = objc_getAssociatedObject(owner, key);
        if (!entries) {
            entries = [NSMutableDictionary new];
            objc_setAssociatedObject(owner, key, entries, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        entries[name] = status;
    }
}
