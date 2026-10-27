#import <Foundation/Foundation.h>

#ifdef __cplusplus
extern "C" {
#endif

NS_ASSUME_NONNULL_BEGIN

typedef id _Nullable (^TGExtraNativeProcessor)(id root, NSData *packet,
    NSString *_Nullable account, int32_t function, NSData *_Nullable request);

// Root C ABI is checked against the shipped profiles before this is enabled.
BOOL TGExtraNativeInstall(NSData *constructorIds, NSData *policyTypes, TGExtraNativeProcessor processor);
BOOL TGExtraNativeReady(void);
id _Nullable TGExtraNativePacket(NSData *data, NSString *_Nullable account, int32_t function, NSData *_Nullable request);
id _Nullable TGExtraNativeBegin(id _Nullable packet);
void TGExtraNativeEnd(id _Nullable previous);

@interface TGExtraNativeObject : NSObject
- (nullable instancetype)initWithObject:(id)object;
@property(nonatomic, readonly) id object;
@property(nonatomic, readonly) uint32_t constructorId;
@property(nonatomic, readonly) uint16_t typeIndex;
@property(nonatomic, readonly) uint16_t fieldCount;
- (nullable const void *)scalarAtIndex:(NSInteger)index;
- (nullable id)valueAtIndex:(NSInteger)index;
- (BOOL)canSetValue:(nullable id)value atIndex:(NSInteger)index;
- (BOOL)setValue:(nullable id)value atIndex:(NSInteger)index;
@end

// Used only for new constructors/entities and persisted snapshots, never to
// decode the incoming packet a second time. The result owns its native storage.
id _Nullable TGExtraNativeCreate(NSData *wire);

#ifdef TGEXTRA_TESTING
BOOL TGExtraNativeTestConfig(NSDictionary *config, NSData *uuid, uintptr_t constructor, uintptr_t result);
void TGExtraNativeTestInstall(void *constructorParser, void *resultParser, TGExtraNativeProcessor _Nullable processor);
#endif

// Each rule is five UInt32 words: constructor ID, flags/value field indices,
// required setting bits, flag mask and operation (clear flag / remove optional).
typedef NS_OPTIONS(uint32_t, TGExtraNativeSettings) {
    TGExtraNativeSettingsBypassForwarding = 1u << 0,
    TGExtraNativeSettingsBypassPrivateCopy = 1u << 1,
};
void TGExtraNativeSetRules(NSData *rules, uint16_t userType);
void TGExtraNativeSetTraversal(NSData *typeOffsets, NSData *plans);
NSArray *TGExtraNativeObjects(id root);
NSArray *TGExtraNativeApplyRoot(id root, TGExtraNativeSettings settings);

NS_ASSUME_NONNULL_END

#ifdef __cplusplus
}
#endif
