#import <Foundation/Foundation.h>

typedef BOOL (^TGExtraProfileOpener)(void);

@interface TGExtraProfileNavigation : NSObject
+ (void)loadProfileForPeerId:(NSNumber *)peerId
                  fromNode:(id)node
                completion:(void (^)(TGExtraProfileOpener openProfile))completion;
@end
