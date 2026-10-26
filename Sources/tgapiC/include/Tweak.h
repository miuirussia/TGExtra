#import <Foundation/Foundation.h>
#import <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

NSData *decompressGzip(const void *input, size_t inputLen);
NSString *TGExtraHistoryAccountForPath(NSString *path);
NSString *TGExtraHistoryAccountForMTProto(id mtProto);
NSString *TGExtraHistoryAccountForRequestService(id service);
void TGExtraSetHistoryRequestService(id request, id service);
NSString *TGExtraHistoryAccountForRequest(id request);
BOOL TGExtraIsGhostException(int64_t userId);
bool TGExtraReplaceSwiftgramStatusWitness(const void *targetTable, const void *sourceTable);
bool TGExtraSwiftgramStatusHasExpectedField(const void *metadata, const void *int64Metadata);

#ifdef __cplusplus
}
#endif
