#import <Foundation/Foundation.h>

@interface TGExtraPeerInfoStore : NSObject
+ (NSDictionary<NSString *, NSString *> *)cachedPeerInfoForId:(NSNumber *)peerId;
@end
