#import <Foundation/Foundation.h>

@interface TGExtraProfileBridge : NSObject
@property(class, nonatomic, weak) id sharedContext;
+ (NSNumber *)getPeerIdFromNode:(id)node;
+ (id)getTitleNodeFromNode:(id)node;
+ (BOOL)isMutualContactFromNode:(id)node;
+ (id)getInfoSectionFromNode:(id)node;
+ (BOOL)shouldShowProfileInfoFromNode:(id)node;
+ (NSNumber *)getPaneOriginFromNode:(id)node contentHeight:(double)height;
+ (id)getStoredField:(NSString *)field fromNode:(id)node;
+ (NSNumber *)getCurrentUserId;
+ (NSNumber *)getOwnUserIdFromNode:(id)node;
+ (NSDictionary<NSString *, NSString *> *)getPeerDisplayInfoFromNode:(id)node;
+ (NSString *)debugPeerCandidates:(id)node;
@end
