#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>

#ifdef __cplusplus
extern "C" {
#endif
NSDictionary *tgextraRewriteToVoice(id value, id editingContext);
AVAsset *tgextraResolveAVAsset(NSDictionary *dict);
CMTimeRange tgextraTrimRange(id editingContext, id item, AVAsset *asset);
NSDictionary *tgextraRewriteToRound(id value, id editingContext);
#ifdef __cplusplus
}
#endif
