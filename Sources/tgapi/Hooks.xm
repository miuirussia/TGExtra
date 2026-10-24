#import "Headers.h"
#import "ForwardCopy.h"

%hook MTRequest
%property(nonatomic, strong) NSData *fakeData;
%property(nonatomic, strong) NSNumber *functionID;

- (void)setPayload:(NSData *)payload metadata:(id)metadata shortMetadata:(id)shortMetadata responseParser:(id (^)(NSData *))responseParser {
    if (TGExtraIsInternalCopyRequest(self) || TGExtraIsPreparingReadContentsRequest(self)) {
        %orig;
        return;
    }
    self.fakeData = nil;
    TGExtraSetHistoryRequestService(self, nil);
    if (payload.length < 4 || !responseParser) {
        %orig;
        return;
    }
    int32_t functionID = 0;
    [payload getBytes:&functionID length:4];
    self.functionID = @(functionID);
    payload = TGExtraRewriteRequestPayload(payload);
    self.fakeData = TGExtraFakeResponseForPayload(payload);
    __weak MTRequest *weakRequest = self;
    id (^wrappedParser)(NSData *) = ^id(NSData *data) {
        NSData *patched = [TLParser handleResponse:data functionID:@(functionID)
                                          account:TGExtraHistoryAccountForRequest(weakRequest)
                                   requestPayload:weakRequest.payload];
        return responseParser(patched ?: data);
    };
    %orig(payload, metadata, shortMetadata, wrappedParser);
}
%end

%hook MTRequestMessageService
- (void)addRequest:(MTRequest *)request {
    if (TGExtraIsInternalCopyRequest(request)) {
        %orig;
        return;
    }
    TGExtraSetHistoryRequestService(request, self);
    TGExtraPrepareReadContentsRequest(request, TGExtraHistoryAccountForRequest(request));
    TGExtraWrapForwardRequest(request, self);
    if (request.fakeData && request.completed && request.responseParser) {
        MTRequestResponseInfo *info = [[%c(MTRequestResponseInfo) alloc]
            initWithNetworkType:1 timestamp:NSDate.date.timeIntervalSince1970 duration:0.045];
        id result = request.responseParser(request.fakeData);
        request.completed(result, info, nil);
        return;
    }
    %orig;
}

- (void)removeRequestByInternalId:(id)internalId {
    TGExtraCancelForwardRequest(internalId, self);
    %orig;
}

- (void)removeRequestByInternalId:(id)internalId askForReconnectionOnDrop:(bool)askForReconnectionOnDrop {
    TGExtraCancelForwardRequest(internalId, self);
    %orig;
}
%end

%hook MTProto
- (id)parseMessage:(NSData *)data {
    NSData *patched = [TLParser stripAntiSelfDestruct:data account:TGExtraHistoryAccountForMTProto(self)];
    return %orig(patched ?: data);
}
%end
