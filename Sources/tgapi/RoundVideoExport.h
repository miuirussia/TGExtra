#import <AVFoundation/AVFoundation.h>

#ifdef __cplusplus
extern "C" {
#endif
NSURL *TGExtraExportRoundVideo(AVAsset *asset, CMTimeRange range);
CGImageRef TGExtraCopyRoundVideoPreview(AVAsset *asset) CF_RETURNS_RETAINED;
#ifdef __cplusplus
}
#endif
