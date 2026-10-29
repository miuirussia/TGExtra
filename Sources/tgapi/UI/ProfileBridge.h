#import <Foundation/Foundation.h>

@interface TGExtraProfileBridge : NSObject
@property(class, nonatomic, strong) id sharedContext;
+ (NSNumber *)getPeerIdFromNode:(id)node;
+ (NSNumber *)getCurrentUserId;
+ (NSNumber *)getOwnUserIdFromNode:(id)node;
+ (NSDictionary<NSString *, NSString *> *)getPeerDisplayInfoFromNode:(id)node;
+ (NSString *)debugPeerCandidates:(id)node;
@end
