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
BOOL TGExtraIsGhostException(int64_t userId);
NSString *TGExtraRustCompatibilityStatus(void);
NSDictionary<NSString *, NSString *> *TGExtraInstalledHookStatuses(void);

#ifdef __cplusplus
}
#endif
