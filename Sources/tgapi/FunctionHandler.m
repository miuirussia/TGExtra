#import "Headers.h"
#import <objc/runtime.h>
#import "Compatibility.h"

static char ghostReadKey, ghostReplyWrappedKey;

BOOL TGExtraIsGhostReadRequest(MTRequest *request) {
    return [objc_getAssociatedObject(request, &ghostReadKey) boolValue];
}

void TGExtraSendPendingGhostReads(NSData *sentPayload, NSString *account, MTRequestMessageService *service) {
    if (!service || ![NSUserDefaults.standardUserDefaults boolForKey:kGhostModeEnabled] ||
        ![NSUserDefaults.standardUserDefaults boolForKey:kGhostReadOnReply]) return;
    for (NSData *payload in [TLParser pendingGhostReadsAfterSend:sentPayload account:account]) {
        MTRequest *read = [[NSClassFromString(@"MTRequest") alloc] init];
        objc_setAssociatedObject(read, &ghostReadKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [read setPayload:payload metadata:@"TGExtraReadOnReply" shortMetadata:@"TGExtraReadOnReply"
            responseParser:^id(NSData *data) { return data; }];
        read.completed = ^(id result, MTRequestResponseInfo *info, MTRpcError *error) {
            if (!error && result) [TLParser acknowledgeGhostRead:payload account:account];
        };
        [service addRequest:read];
    }
}

void TGExtraPrepareGhostRequest(MTRequest *request, MTRequestMessageService *service) {
    NSString *account = TGExtraHistoryAccountForRequest(request);
    if (request.fakeData) [TLParser noteBlockedRead:request.payload account:account];
    if (request.fakeData || ![NSUserDefaults.standardUserDefaults boolForKey:kGhostReadOnReply] ||
        ![TLParser isGhostReplyPayload:request.payload] ||
        objc_getAssociatedObject(request, &ghostReplyWrappedKey)) return;
    objc_setAssociatedObject(request, &ghostReplyWrappedKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    NSData *payload = request.payload;
    void (^completed)(id, MTRequestResponseInfo *, MTRpcError *) = request.completed;
    __weak MTRequestMessageService *weakService = service;
    request.completed = ^(id result, MTRequestResponseInfo *info, MTRpcError *error) {
        if (completed) completed(result, info, error);
        if (!error && result) TGExtraSendPendingGhostReads(payload, account, weakService);
    };
}

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
