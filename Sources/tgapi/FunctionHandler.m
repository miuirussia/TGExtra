#import "Headers.h"
#import <objc/runtime.h>
#import "Compatibility.h"

NSDictionary<NSString *, NSString *> *TGExtraInstalledHookStatuses(void) {
    return TGExtraHookStatuses();
}

NSData *TGExtraFakeResponseForPayload(NSData *payload) {
    return [TLParser fakeResponseForPayload:payload];
}

NSData *TGExtraRewriteRequestPayload(NSData *payload) {
    return [TLParser rewriteRequestPayload:payload] ?: payload;
}

static char preparingReadContentsKey;

BOOL TGExtraIsPreparingReadContentsRequest(MTRequest *request) {
    return [objc_getAssociatedObject(request, &preparingReadContentsKey) boolValue];
}

void TGExtraPrepareReadContentsRequest(MTRequest *request, NSString *account) {
    if (request.payload.length < 4) return;
    NSDictionary *policy = [TLParser readMessageContentsPolicy:request.payload account:account];
    if (!policy) return;
    request.fakeData = policy[@"response"];
    NSData *payload = policy[@"payload"];
    if (!payload) return;
    objc_setAssociatedObject(request, &preparingReadContentsKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    @try {
        [request setPayload:payload metadata:request.metadata shortMetadata:request.shortMetadata responseParser:request.responseParser];
    } @finally {
        objc_setAssociatedObject(request, &preparingReadContentsKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
}
