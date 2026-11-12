#import "VoiceSelection.h"
#import "Constants.h"
#import "Headers.h"
#import <objc/runtime.h>

BOOL tgextraVideoToVoiceEnabled(void) {
    return [[NSUserDefaults standardUserDefaults] boolForKey:kVideoToVoice];
}

BOOL tgextraVideoToRoundEnabled(void) {
    return [[NSUserDefaults standardUserDefaults] boolForKey:kVideoToRound] && [TLParser roundVideoChatSupported];
}

static const void *kTGExtraVoiceItemsKey = &kTGExtraVoiceItemsKey;
static const void *kTGExtraRoundItemsKey = &kTGExtraRoundItemsKey;

id tgextraVoiceEditingContext(id item) {
    return [item respondsToSelector:@selector(editingContext)] ? [item editingContext] : nil;
}

NSString *tgextraVoiceItemIdentifier(id item) {
    if ([item respondsToSelector:@selector(editableMediaItem)]) item = [item editableMediaItem] ?: item;
    id identifier = [item respondsToSelector:@selector(uniqueIdentifier)] ? [item uniqueIdentifier] : nil;
    if ([identifier isKindOfClass:NSString.class] && [identifier length]) return identifier;
    if ([item isKindOfClass:NSURL.class]) return [item absoluteString];
    if ([item isKindOfClass:NSString.class] && [item length]) {
        return [item hasPrefix:@"file://"] ? item : [NSURL fileURLWithPath:item].absoluteString;
    }
    return nil;
}

NSSet<NSString *> *tgextraVoiceItems(id editingContext) {
    if (!editingContext) return [NSSet set];
    @synchronized(editingContext) {
        return [objc_getAssociatedObject(editingContext, kTGExtraVoiceItemsKey) copy] ?: [NSSet set];
    }
}

NSSet<NSString *> *tgextraRoundItems(id editingContext) {
    if (!editingContext) return [NSSet set];
    @synchronized(editingContext) {
        return [objc_getAssociatedObject(editingContext, kTGExtraRoundItemsKey) copy] ?: [NSSet set];
    }
}

static BOOL tgextraToggleConversionItem(id galleryItem, const void *key, const void *otherKey) {
    id context = tgextraVoiceEditingContext(galleryItem);
    NSString *identifier = tgextraVoiceItemIdentifier(galleryItem);
    if (!context || !identifier) return NO;
    @synchronized(context) {
        NSMutableSet *items = [objc_getAssociatedObject(context, key) mutableCopy] ?: [NSMutableSet set];
        BOOL enabled = ![items containsObject:identifier];
        if (enabled) [items addObject:identifier];
        else [items removeObject:identifier];
        objc_setAssociatedObject(context, key, items,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        if (enabled) {
            NSMutableSet *otherItems = [objc_getAssociatedObject(context, otherKey) mutableCopy];
            [otherItems removeObject:identifier];
            objc_setAssociatedObject(context, otherKey, otherItems, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        return enabled;
    }
}

BOOL tgextraToggleVoiceItem(id galleryItem) {
    return tgextraToggleConversionItem(galleryItem, kTGExtraVoiceItemsKey, kTGExtraRoundItemsKey);
}

BOOL tgextraToggleRoundItem(id galleryItem) {
    return tgextraToggleConversionItem(galleryItem, kTGExtraRoundItemsKey, kTGExtraVoiceItemsKey);
}

void tgextraClearConversionItem(id galleryItem) {
    id context = tgextraVoiceEditingContext(galleryItem);
    NSString *identifier = tgextraVoiceItemIdentifier(galleryItem);
    if (!context || !identifier) return;
    @synchronized(context) {
        for (NSValue *key in @[[NSValue valueWithPointer:kTGExtraVoiceItemsKey],
                              [NSValue valueWithPointer:kTGExtraRoundItemsKey]]) {
            NSMutableSet *items = [objc_getAssociatedObject(context, key.pointerValue) mutableCopy];
            [items removeObject:identifier];
            objc_setAssociatedObject(context, key.pointerValue, items, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
    }
}
