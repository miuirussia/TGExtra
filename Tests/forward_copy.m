#import "Support/TestSupport.h"
#import "../Sources/tgapi/ForwardCopy.h"

extern void TGExtraSetCopyTestDirectory(NSURL *directory);
extern void TGExtraDrainCopyTestQueue(void);

@implementation MTRpcError
- (instancetype)initWithErrorCode:(int32_t)code errorDescription:(NSString *)description {
    if ((self = [super init])) { _errorCode = code; _errorDescription = description; }
    return self;
}
@end
@implementation MTRequestResponseInfo
- (instancetype)initWithNetworkType:(int)a timestamp:(CGFloat)b duration:(CGFloat)c { return [super init]; }
@end

@interface CopyTestContext : NSObject
@property NSMutableDictionary<NSString *, NSMutableArray *> *replies;
@property NSMutableArray<NSData *> *payloads;
@property NSMutableArray *cancellations;
@property dispatch_semaphore_t pending;
@property bool useTempAuthKeys;
@end
@implementation CopyTestContext
@end

@interface MTRequestMessageService ()
@property id mtProto;
@property CopyTestContext *testContext;
@end

@interface MTProto : NSObject
@property CopyTestContext *context;
@property id usageCalculationInfo;
@property NSInteger datacenterId;
@property bool useTempAuthKeys;
@property bool media;
- (instancetype)initWithContext:(id)context datacenterId:(NSInteger)dc usageCalculationInfo:(id)usage requiredAuthToken:(id)token authTokenMasterDatacenterId:(NSInteger)master;
@end
@implementation MTProto
- (instancetype)initWithContext:(id)context datacenterId:(NSInteger)dc usageCalculationInfo:(id)usage requiredAuthToken:(id)token authTokenMasterDatacenterId:(NSInteger)master {
    if ((self = [super init])) {
        _context = context; _datacenterId = dc; _usageCalculationInfo = usage;
        NSCAssert(dc == 1 || ([token isEqual:@(dc)] && master == 1), @"Media DC uses the account's master authorization");
    }
    return self;
}
- (void)addMessageService:(MTRequestMessageService *)service { service.mtProto = self; }
- (void)removeMessageService:(MTRequestMessageService *)service { service.mtProto = nil; }
- (void)resume {}
- (void)stop {}
@end

@implementation MTRequestMessageService
- (instancetype)initWithContext:(CopyTestContext *)context {
    if ((self = [super init])) _testContext = context;
    return self;
}
- (void)addRequest:(MTRequest *)request {
    NSCAssert(TGExtraIsInternalCopyRequest(request), @"Every helper request bypasses host response rewriting");
    int32_t constructor;
    NSCAssert(request.payload.length >= 4, @"Valid helper payload");
    [request.payload getBytes:&constructor length:4];
    id reply;
    @synchronized(self.testContext) {
        [self.testContext.payloads addObject:request.payload];
        NSMutableArray *replies = self.testContext.replies[@(constructor).stringValue];
        reply = replies.firstObject;
        if (reply) [replies removeObjectAtIndex:0];
    }
    if ([reply isKindOfClass:NSDictionary.class] && [reply[@"hold"] boolValue]) {
        dispatch_semaphore_signal(self.testContext.pending);
        return;
    }
    MTRpcError *error;
    if (![reply isKindOfClass:NSData.class]) {
        error = [[MTRpcError alloc] initWithErrorCode:400 errorDescription:reply[@"error"] ?: @"TEST_UNEXPECTED_REQUEST"];
    }
    MTRequestResponseInfo *info = [[MTRequestResponseInfo alloc] initWithNetworkType:1 timestamp:1234 duration:0.1];
    request.completed(error ? nil : request.responseParser(reply), info, error);
}
- (void)removeRequestByInternalId:(id)internalId {
    @synchronized(self.testContext) { [self.testContext.cancellations addObject:internalId]; }
}
- (void)removeRequestByInternalId:(id)internalId askForReconnectionOnDrop:(bool)value { [self removeRequestByInternalId:internalId]; }
@end

NSDictionary *TGExtraRunForwardCopyScenario(NSDictionary *fixture, NSURL *journalDirectory) {
    TGExtraSetCopyTestDirectory(journalDirectory);
    CopyTestContext *context = [CopyTestContext new];
    context.payloads = [NSMutableArray new]; context.cancellations = [NSMutableArray new];
    context.pending = dispatch_semaphore_create(0); context.replies = [NSMutableDictionary new];
    [fixture[@"replies"] enumerateKeysAndObjectsUsingBlock:^(NSString *key, NSArray *replies, BOOL *stop) {
        context.replies[key] = replies.mutableCopy;
    }];
    // usageCalculationInfo.filePath is the same account attribution path used
    // by the injected hook. Dictionaries support these KVC keys in the mock.
    NSString *account = fixture[@"account"] ?: @"account-1";
    MTProto *network = [[MTProto alloc] initWithContext:context datacenterId:1
        usageCalculationInfo:@{@"filePath": [NSString stringWithFormat:@"/accounts/%@/network-stats", account]}
        requiredAuthToken:nil authTokenMasterDatacenterId:0];
    MTRequestMessageService *service = [[MTRequestMessageService alloc] initWithContext:context];
    [network addMessageService:service];
    MTRequest *request = [MTRequest new];
    [request setPayload:fixture[@"payload"] metadata:nil shortMetadata:nil responseParser:^id(NSData *bytes) { return bytes; }];
    dispatch_semaphore_t completed = dispatch_semaphore_create(0);
    __block NSUInteger count = 0;
    __block NSData *result;
    __block NSString *errorDescription;
    request.completed = ^(id reply, MTRequestResponseInfo *info, MTRpcError *error) {
        count++; result = reply; errorDescription = error.errorDescription;
        dispatch_semaphore_signal(completed);
    };
    TGExtraWrapForwardRequest(request, service);
    NSString *initial = fixture[@"initialError"] ?: @"CHAT_FORWARDS_RESTRICTED";
    request.completed(fixture[@"initialResult"], nil, initial.length ? [[MTRpcError alloc] initWithErrorCode:400 errorDescription:initial] : nil);
    BOOL cancel = [fixture[@"cancel"] boolValue];
    if (cancel) {
        NSCAssert(dispatch_semaphore_wait(context.pending, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC)) == 0, @"Cancellation scenario reached its pending helper");
        TGExtraCancelForwardRequest(request.internalId, service);
    } else {
        NSCAssert(dispatch_semaphore_wait(completed, dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_SEC)) == 0, @"Scenario completed without hanging");
    }
    TGExtraDrainCopyTestQueue();
    @synchronized(context) {
        return @{@"result": result ?: NSData.data, @"error": errorDescription ?: @"", @"completions": @(count),
            @"payloads": context.payloads.copy, @"cancellations": @(context.cancellations.count)};
    }
}
