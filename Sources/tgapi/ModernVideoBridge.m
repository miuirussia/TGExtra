#import "../tgapiC/include/VideoConversion.h"
#import <objc/runtime.h>
#import <dlfcn.h>
#ifndef TGEXTRA_TESTING
#import "UI/TGExtraLocalization.h"
#endif

@interface NSObject (TGExtraModernVideo)
+ (id)editAdjustmentsWithDictionary:(NSDictionary *)dictionary;
- (id)adjustmentsForItem:(id)item;
- (void)setAdjustments:(id)adjustments forItem:(id)item;
- (NSOrderedSet *)selectedItemsIdentifiers;
@end

id TGExtraVideoAdjustments(NSDictionary *values) {
    Class cls = objc_getClass("TGVideoEditAdjustments");
    return [cls respondsToSelector:@selector(editAdjustmentsWithDictionary:)]
        ? [cls editAdjustmentsWithDictionary:values] : nil;
}

id TGExtraGetVideoAdjustments(id context, id item) {
    return [context respondsToSelector:@selector(adjustmentsForItem:)] ? [context adjustmentsForItem:item] : nil;
}

BOOL TGExtraSetVideoAdjustments(id context, id item, id adjustments) {
    if (![context respondsToSelector:@selector(setAdjustments:forItem:)]) return NO;
    [context setAdjustments:adjustments forItem:item];
    return YES;
}

NSString *TGExtraModernVideoString(NSString *key) {
#ifdef TGEXTRA_TESTING
    return key;
#else
    return [TGExtraLocalization localizedStringForKey:key];
#endif
}

NSArray<NSString *> *TGExtraSelectedVideoIdentifiers(id selection) {
    return [selection respondsToSelector:@selector(selectedItemsIdentifiers)]
        ? [selection selectedItemsIdentifiers].array : @[];
}

// Swift stored callbacks have a concrete ABI. A cast through a generic Swift
// function type reabstracts String/Bool arguments into indirect arguments.
typedef bool __attribute__((swiftcall)) (*ModernSend)(uintptr_t, uintptr_t, bool, uint64_t, const void *, void *, void * __attribute__((swift_context)));
typedef void * __attribute__((swiftcall)) (*ModernLookup)(uintptr_t, uintptr_t, void * __attribute__((swift_context)));
typedef void * __attribute__((swiftcall)) (*ModernAsset)(NSInteger, void * __attribute__((swift_context)));
typedef void __attribute__((swiftcall)) (*ModernCompletion)(void * __attribute__((swift_context)));
extern bool TGExtraModernVideoSend(void *context, const void *identifier, bool silent, uint64_t time, const void *completion, void *completionContext);
extern void TGExtraModernVideoCompleted(void *context);

void TGExtraRetainModernVideoContext(void *context) {
    void *(*retain)(void *) = dlsym(RTLD_DEFAULT, "swift_retain");
    if (context) retain(context);
}
void TGExtraReleaseModernVideoContext(void *context) {
    void (*release)(void *) = dlsym(RTLD_DEFAULT, "swift_release");
    if (context) release(context);
}
static void __attribute__((swiftcall)) modernCompleted(void *context __attribute__((swift_context))) {
    TGExtraModernVideoCompleted(context);
}
static bool __attribute__((swiftcall)) modernSend(uintptr_t first, uintptr_t second, bool silent, uint64_t time,
                                                const void *complete, void *completeContext,
                                                void *context __attribute__((swift_context))) {
    uintptr_t identifier[] = {first, second};
    return TGExtraModernVideoSend(context, identifier, silent, time, complete, completeContext);
}
void TGExtraInstallModernVideoSend(void *slot, void *context) {
    uintptr_t *words = slot;
    void *previous = (void *)words[1];
    TGExtraRetainModernVideoContext(context);
    words[0] = (uintptr_t)modernSend;
    words[1] = (uintptr_t)context;
    TGExtraReleaseModernVideoContext(previous);
}
BOOL TGExtraInvokeModernVideoSend(const void *function, void *context, const void *identifier, BOOL silent, uint64_t time, void *completion) {
    const uintptr_t *words = identifier;
    return ((ModernSend)function)(words[0], words[1], silent, time, modernCompleted, completion, context);
}
id TGExtraInvokeModernVideoLookup(const void *function, void *context, const void *identifier) {
    const uintptr_t *words = identifier;
    return (__bridge_transfer id)((ModernLookup)function)(words[0], words[1], context);
}
id TGExtraInvokeModernVideoAsset(const void *function, void *context, NSInteger index) {
    return (__bridge_transfer id)((ModernAsset)function)(index, context);
}
void TGExtraInvokeModernVideoCompletion(const void *function, void *context) {
    ((ModernCompletion)function)(context);
}
