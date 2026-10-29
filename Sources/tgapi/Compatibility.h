#import <Foundation/Foundation.h>
#import <objc/runtime.h>

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
