#import <Foundation/Foundation.h>
#import "NativeTL.h"

#ifdef __cplusplus
extern "C" {
#endif

NSData *decompressGzip(const void *input, size_t inputLen);
NSData *TGExtraHostTLSchema(void);
NSString *TGExtraHistoryAccountForPath(NSString *path);
NSString *TGExtraHistoryAccountForMTProto(id mtProto);
NSString *TGExtraHistoryAccountForRequestService(id service);
void TGExtraSetHistoryRequestService(id request, id service);
NSString *TGExtraHistoryAccountForRequest(id request);
BOOL TGExtraMessageCleanupAvailable(void);
void TGExtraRunMessageCleanup(void *postbox, void *context, const void *voidMetadata);
void TGExtraDeleteLocalMessages(void *transaction, void *ids, BOOL global);
void TGExtraDeleteLocalMessageRange(void *transaction, uint32_t peerNamespace, int64_t peer, int32_t messageNamespace, int32_t maxId);
void TGExtraVisitLocalMessages(void *transaction, uint32_t peerNamespace, int64_t peer, void *context);
BOOL TGExtraIsGhostException(int64_t userId);
NSString *TGExtraRustCompatibilityStatus(void);
NSDictionary<NSString *, NSString *> *TGExtraInstalledHookStatuses(void);

#ifdef __cplusplus
}
#endif
