#import <Foundation/Foundation.h>

@interface TGExtraPaidMediaFile : NSObject
@property(nonatomic, readonly) NSObject *context;
@property(nonatomic, readonly) NSInteger masterDatacenterId;
@property(nonatomic, readonly) NSInteger datacenterId;
@property(nonatomic, readonly) int64_t size;
@property(nonatomic, readonly) BOOL video;
@property(nonatomic, readonly) NSString *cachePath;
+ (instancetype)fileFromFooterNode:(id)footer;
+ (BOOL)isUnlockedPaidItem:(id)item;
+ (void)bindGalleryItem:(id)item;
+ (id)contentNodeFromFooter:(id)footer;
+ (id)footerNodeFromItem:(id)item;
+ (double)bottomInsetFromFooter:(id)footer;
- (NSData *)downloadRequestAtOffset:(int64_t)offset;
- (BOOL)beginNativeDownload;
@property(nonatomic, readonly) NSNumber *nativeDownloadProgress;
@end

// Completion runs on the main queue. Its temporary file is valid until the
// caller removes it, including while Photos reads it asynchronously.
void TGExtraDownloadPaidMedia(TGExtraPaidMediaFile *file, void (^completion)(NSURL *, NSError *));

#ifdef __cplusplus
extern "C" {
#endif
void TGExtraUpdatePaidMediaSaveButton(id node);
void TGExtraUpdatePaidMediaCapture(id node);
#ifdef __cplusplus
}
#endif
