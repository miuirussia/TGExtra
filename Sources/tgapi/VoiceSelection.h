#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

#ifdef __cplusplus
extern "C" {
#endif
BOOL tgextraVideoToVoiceEnabled(void);
BOOL tgextraVideoToRoundEnabled(void);
id tgextraVoiceProperty(id object, NSString *name);
NSString *tgextraVoiceItemIdentifier(id item);
NSSet<NSString *> *tgextraVoiceItems(id editingContext);
BOOL tgextraToggleVoiceItem(id galleryItem);
NSSet<NSString *> *tgextraRoundItems(id editingContext);
BOOL tgextraToggleRoundItem(id galleryItem);
#ifdef __cplusplus
}
#endif
