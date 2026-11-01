#import <Foundation/Foundation.h>

@interface NSObject (TGExtraVoiceMediaItem)
- (id)editableMediaItem;
- (NSString *)uniqueIdentifier;
- (id)editingContext;
- (id)backingItem;
@end

#ifdef __cplusplus
extern "C" {
#endif
BOOL tgextraVideoToVoiceEnabled(void);
BOOL tgextraVideoToRoundEnabled(void);
id tgextraVoiceEditingContext(id item);
NSString *tgextraVoiceItemIdentifier(id item);
NSSet<NSString *> *tgextraVoiceItems(id editingContext);
BOOL tgextraToggleVoiceItem(id galleryItem);
NSSet<NSString *> *tgextraRoundItems(id editingContext);
BOOL tgextraToggleRoundItem(id galleryItem);
#ifdef __cplusplus
}
#endif
