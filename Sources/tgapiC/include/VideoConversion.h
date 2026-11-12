#import <Foundation/Foundation.h>

#ifdef __cplusplus
extern "C" {
#endif

BOOL tgextraVideoToVoiceEnabled(void);
BOOL tgextraVideoToRoundEnabled(void);
NSSet<NSString *> *tgextraVoiceItems(id context);
NSSet<NSString *> *tgextraRoundItems(id context);
BOOL tgextraToggleVoiceItem(id item);
BOOL tgextraToggleRoundItem(id item);
void tgextraClearConversionItem(id item);
id TGExtraVideoAdjustments(NSDictionary *values);
id TGExtraGetVideoAdjustments(id context, id item);
BOOL TGExtraSetVideoAdjustments(id context, id item, id adjustments);
NSString *TGExtraModernVideoString(NSString *key);
NSArray<NSString *> *TGExtraSelectedVideoIdentifiers(id selection);
void TGExtraInstallModernVideoSend(void *slot, void *context);
BOOL TGExtraInvokeModernVideoSend(const void *function, void *context, const void *identifier, BOOL silent, uint64_t time, void *completion);
id TGExtraInvokeModernVideoLookup(const void *function, void *context, const void *identifier);
id TGExtraInvokeModernVideoAsset(const void *function, void *context, NSInteger index);
void TGExtraInvokeModernVideoCompletion(const void *function, void *context);
void TGExtraRetainModernVideoContext(void *context);
void TGExtraReleaseModernVideoContext(void *context);

#ifdef __cplusplus
}
#endif
