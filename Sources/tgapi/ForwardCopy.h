#import "Headers.h"

// Selectors implemented by TGExtra's Swift protocol codec, not host Swift APIs.
@interface TGExtraForwardCopyPlan : NSObject
- (instancetype)initWithPayload:(NSData *)payload;
@property(nonatomic, readonly) NSString *errorDescription;
@property(nonatomic, readonly) NSData *sourceRequest;
@property(nonatomic, readonly) NSArray<NSDictionary *> *downloads;
@property(nonatomic, readonly) NSArray<NSDictionary *> *requests;
+ (NSString *)operationKeyForAccount:(NSString *)account payload:(NSData *)payload;
- (BOOL)prepareWithResponse:(NSData *)response;
- (NSData *)downloadRequestForIndex:(NSInteger)index offset:(int64_t)offset;
- (BOOL)refreshDownloadWithResponse:(NSData *)response index:(NSInteger)index;
+ (NSData *)fileBytesFromResponse:(NSData *)response;
+ (NSData *)uploadRequestForFileId:(int64_t)fileId part:(int32_t)part total:(int32_t)total bytes:(NSData *)bytes big:(BOOL)big;
+ (BOOL)isUploadAcknowledged:(NSData *)response;
- (NSData *)mediaUploadRequestForIndex:(NSInteger)index fileId:(int64_t)fileId parts:(int32_t)parts md5:(NSString *)md5;
- (BOOL)registerMediaResponse:(NSData *)response index:(NSInteger)index;
- (BOOL)buildRequests;
- (BOOL)restoreRequests:(NSArray<NSDictionary *> *)requests;
- (NSData *)confirmationRequestForResponse:(NSData *)response;
- (NSData *)normalizeResponse:(NSData *)response confirmation:(NSData *)confirmation batch:(NSInteger)batch;
+ (NSData *)mergeResponses:(NSArray<NSData *> *)responses;
@end

#ifdef __cplusplus
extern "C" {
#endif
BOOL TGExtraIsInternalCopyRequest(MTRequest *request);
void TGExtraWrapForwardRequest(MTRequest *request, MTRequestMessageService *service);
void TGExtraCancelForwardRequest(id internalId, MTRequestMessageService *service);
#ifdef __cplusplus
}
#endif
