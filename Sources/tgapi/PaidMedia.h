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

void TGExtraDownloadPaidMedia(TGExtraPaidMediaFile *file, void (^completion)(NSURL *, NSError *));
void TGExtraImportPaidMedia(NSURL *url, BOOL video, void (^completion)(NSString *, NSError *));

#ifdef __cplusplus
extern "C" {
#endif
void TGExtraUpdatePaidMediaSaveButton(id node);
void TGExtraUpdatePaidMediaCapture(id node);
#ifdef __cplusplus
}
#endif
