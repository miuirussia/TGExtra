#import "Headers.h"

#define kChannelsReadHistory -871347913

%hook MTRequest
%property(nonatomic, strong) NSData *fakeData;
%property(nonatomic, strong) NSNumber *functionID;

- (void)setPayload:(NSData *)payload metadata:(id)metadata shortMetadata:(id)shortMetadata responseParser:(id (^)(NSData *))responseParser {
    self.fakeData = nil;
    if (payload.length < 4 || !responseParser) {
        %orig;
        return;
    }
    int32_t functionID = 0;
    [payload getBytes:&functionID length:4];
    self.functionID = @(functionID);
    if (functionID == kMessagesSendMedia || functionID == kMessagesSendMultiMedia ||
        functionID == kMessagesUploadMedia) {
        payload = [TLParser rewriteVoiceUpload:payload] ?: payload;
    }
    switch (functionID) {
        case kAccountUpdateOnlineStatus: handleOnlineStatus(self, payload); break;
        case kMessagesSetTypingAction: handleSetTyping(self, payload); break;
        case kMessagesReadHistory: handleMessageReadReceipt(self, payload); break;
        case kStoriesReadStories: handleStoriesReadReceipt(self, payload); break;
        case kGetSponsoredMessages: handleGetSponsoredMessages(self, payload); break;
        case kChannelsReadHistory: handleChannelsReadReceipt(self, payload); break;
        case kSendScreenshotNotification: handleSendScreenshotNotification(self, payload); break;
        case kChannelsReadMessageContents:
            if ([[NSUserDefaults standardUserDefaults] boolForKey:kAntiSelfDestruct]) {
                uint32_t value = 0x997275b5;
                self.fakeData = [NSData dataWithBytes:&value length:4];
            }
            break;
        case kMessagesReadMessageContents: handleReadMessageContents(self, payload); break;
    }
    id (^wrappedParser)(NSData *) = ^id(NSData *data) {
        NSData *patched = [TLParser handleResponse:data functionID:@(functionID)];
        return responseParser(patched ?: data);
    };
    %orig(payload, metadata, shortMetadata, wrappedParser);
}
%end

%hook MTRequestMessageService
- (void)addRequest:(MTRequest *)request {
    if (request.fakeData && request.completed && request.responseParser) {
        MTRequestResponseInfo *info = [[%c(MTRequestResponseInfo) alloc]
            initWithNetworkType:1 timestamp:NSDate.date.timeIntervalSince1970 duration:0.045];
        id result = request.responseParser(request.fakeData);
        request.completed(result, info, nil);
        return;
    }
    %orig;
}
%end

%hook MTProto
- (id)parseMessage:(NSData *)data {
    NSData *patched = [TLParser stripAntiSelfDestruct:data];
    return %orig(patched ?: data);
}
%end
