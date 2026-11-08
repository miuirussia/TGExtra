#import <Foundation/Foundation.h>

typedef BOOL (^TGExtraProfileOpener)(void);

@interface TGExtraProfileNavigation : NSObject
+ (void)rememberProfileForPeerId:(NSNumber *)peerId fromNode:(id)node;
+ (void)loadProfileForPeerId:(NSNumber *)peerId
                  fromNode:(id)node
                completion:(void (^)(TGExtraProfileOpener openProfile))completion;
@end
