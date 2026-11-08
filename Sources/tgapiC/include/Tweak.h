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
BOOL TGExtraProfileLookupAvailable(void);
void TGExtraLogProfileFailure(int64_t userId, NSString *reason);
void TGExtraRunProfileLookup(void *postbox, void *context, const void *voidMetadata);
BOOL TGExtraCopyProfilePeer(void *transaction, int64_t userId, void *result);
BOOL TGExtraProfileRefreshAvailable(void);
void *TGExtraRefreshProfilePeer(void *engine, int64_t userId, int64_t accessHash, void *context);
void TGExtraDisposeProfileRefresh(void *token);
void TGExtraInvokeProfileAction(const void *function, const void *context, const void *peer);
NSString *TGExtraRustCompatibilityStatus(void);
NSDictionary<NSString *, NSString *> *TGExtraInstalledHookStatuses(void);

#ifdef __cplusplus
}
#endif
