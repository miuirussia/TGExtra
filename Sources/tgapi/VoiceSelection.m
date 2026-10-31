#import "VoiceSelection.h"
#import "Constants.h"
#import <objc/runtime.h>
#import <objc/message.h>

BOOL tgextraVideoToVoiceEnabled(void) {
    return [[NSUserDefaults standardUserDefaults] boolForKey:kVideoToVoice];
}

BOOL tgextraVideoToRoundEnabled(void) {
    return [[NSUserDefaults standardUserDefaults] boolForKey:kVideoToRound];
}

static const void *kTGExtraVoiceItemsKey = &kTGExtraVoiceItemsKey;
static const void *kTGExtraRoundItemsKey = &kTGExtraRoundItemsKey;

id tgextraVoiceProperty(id object, NSString *name) {
    SEL selector = NSSelectorFromString(name);
    return [object respondsToSelector:selector]
        ? ((id (*)(id, SEL))objc_msgSend)(object, selector) : nil;
}

NSString *tgextraVoiceItemIdentifier(id item) {
    item = tgextraVoiceProperty(item, @"editableMediaItem") ?: item;
    id identifier = tgextraVoiceProperty(item, @"uniqueIdentifier");
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
    id context = tgextraVoiceProperty(galleryItem, @"editingContext");
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
