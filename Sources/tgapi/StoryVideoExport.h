#import <Foundation/Foundation.h>

#ifdef __cplusplus
extern "C" {
#endif
BOOL TGExtraStoryVideoNeedsNormalization(NSURL *inputURL);
// Blocks the caller; use only on a background queue. The caller owns a
// successful output and must remove it after Photos finishes importing it.
NSURL *TGExtraExportStoryVideo(NSURL *inputURL);
#ifdef __cplusplus
}
#endif
