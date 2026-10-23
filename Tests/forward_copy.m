#import "Support/TestSupport.h"
#import "../Sources/tgapi/ForwardCopy.h"
#import "../Sources/tgapi/RustBridge.h"

extern void TGExtraSetCopyTestDirectory(NSURL *directory);
extern void TGExtraDrainCopyTestQueue(void);

@implementation MTRpcError
- (instancetype)initWithErrorCode:(int32_t)code errorDescription:(NSString *)description {
    if ((self = [super init])) { _errorCode = code; _errorDescription = description; }
    return self;
}
@end
@implementation MTRequestResponseInfo
- (instancetype)initWithNetworkType:(int)a timestamp:(CGFloat)b duration:(CGFloat)c { if ((self = [super init])) { _networkType = a; _timestamp = b; _duration = c; } return self; }
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

static NSDictionary *runRustCopyScenario(NSDictionary *fixture, CopyTestContext *context);

NSDictionary *TGExtraRunForwardCopyScenario(NSDictionary *fixture, NSURL *journalDirectory) {
    TGExtraSetCopyTestDirectory(journalDirectory);
    CopyTestContext *context = [CopyTestContext new];
    context.payloads = [NSMutableArray new]; context.cancellations = [NSMutableArray new];
    context.pending = dispatch_semaphore_create(0); context.replies = [NSMutableDictionary new];
    [fixture[@"replies"] enumerateKeysAndObjectsUsingBlock:^(NSString *key, NSArray *replies, BOOL *stop) {
        context.replies[key] = replies.mutableCopy;
    }];
    if ([fixture[@"rust"] boolValue]) return runRustCopyScenario(fixture, context);
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

@interface CopyTestRustEngine : NSObject
@property CopyTestContext *context;
@property NSDictionary *fixture;
@property TGERustEventCallback callback;
@property dispatch_queue_t queue;
@property dispatch_semaphore_t completed;
@property dispatch_semaphore_t initialGate;
@property NSMutableSet<NSNumber *> *held;
@property NSMutableArray<NSString *> *sequence;
@property uint64_t counter;
@property NSUInteger completions;
@property NSData *result;
@property NSString *error;
@property BOOL destroyed;
@property NSUInteger activity;
@end
@implementation CopyTestRustEngine
@end

static const uint8_t *copyRustData(const void *buffer) { return [(__bridge NSData *)buffer bytes]; }
static size_t copyRustLength(const void *buffer) { return [(__bridge NSData *)buffer length]; }
static void copyRustFree(void *buffer) { id data = CFBridgingRelease(buffer); (void)data; }

static void copyRustDeliver(CopyTestRustEngine *engine, uint64_t identifier, id reply, int32_t code) {
    NSData *bytes = [reply isKindOfClass:NSData.class] ? reply : nil;
    NSString *error = [reply isKindOfClass:NSString.class] ? reply : nil;
    NSData *text = [error dataUsingEncoding:NSUTF8StringEncoding];
    TGERustEvent event = {0};
    event.kind = error ? 2 : 1; event.requestId = identifier; event.code = error ? code : 0;
    event.text = (TGERustString){text.bytes, text.length};
    event.value1 = 1234; event.value2 = 0.1;
    if (bytes) event.payload = (__bridge_retained void *)bytes;
    engine.callback((__bridge void *)engine, 1, &event);
}

static void copyRustHostEvent(void *context, uint64_t session, const TGERustEvent *event) {
    CopyTestRustEngine *engine = (__bridge id)context;
    NSData *result;
    if (event->payload) {
        size_t length = [TGExtraRustBridge bufferLength:event->payload original:copyRustLength];
        const uint8_t *bytes = [TGExtraRustBridge bufferData:event->payload original:copyRustData];
        result = [NSData dataWithBytes:bytes length:length];
        // Synthetic completion tokens must never be passed to the real Rust
        // buffer free; CFBridgingRelease in this mock would crash if they were.
        [TGExtraRustBridge bufferFree:event->payload original:copyRustFree];
    }
    if (event->requestId != 8001) {
        if (event->kind == 1 && !event->payload) engine.activity++;
        return;
    }
    @synchronized(engine.context) {
        engine.completions++;
        engine.result = result;
        engine.error = event->kind == 2 ? [[NSString alloc] initWithBytes:event->text.data length:event->text.length encoding:NSUTF8StringEncoding] : @"";
        [engine.sequence addObject:@"completed"];
    }
    dispatch_semaphore_signal(engine.completed);
}
static void *copyRustCreate(uint32_t threads, void *context, void *callback, void *log) {
    CopyTestRustEngine *engine = (__bridge id)context;
    engine.callback = (TGERustEventCallback)callback;
    return context;
}
static uint64_t copyRustSession(void *engine, const void *setup) { return 1; }
static void *copyRustUsage(void *receiver, void *selector, void *info) { return receiver; }
static void *copyRustAuth(void *receiver, void *selector, NSInteger dc, NSInteger authSelector) { return NULL; }
static uint64_t copyRustNext(void *pointer) {
    CopyTestRustEngine *engine = (__bridge id)pointer;
    return ++engine.counter;
}
static void copyRustSend(void *pointer, uint64_t session, const TGERustRequest *request) {
    CopyTestRustEngine *engine = (__bridge id)pointer;
    uint64_t identifier = request->id;
    NSData *payload = [NSData dataWithBytes:request->body.data length:request->body.length];
    if (identifier == 8001) {
        dispatch_async(engine.queue, ^{
            NSCAssert(dispatch_semaphore_wait(engine.initialGate, dispatch_time(DISPATCH_TIME_NOW, 5*NSEC_PER_SEC)) == 0, @"Original refusal gate released");
            NSString *initial = engine.fixture[@"initialError"] ?: @"CHAT_FORWARDS_RESTRICTED";
            copyRustDeliver(engine, identifier, initial.length ? initial : (engine.fixture[@"initialResult"] ?: NSData.data),
                [engine.fixture[@"initialCode"] intValue] ?: 400);
        });
        return;
    }
    if (identifier == 9002 || identifier == 9003) {
        @synchronized(engine.context) { [engine.sequence addObject:identifier == 9002 ? @"dependent" : @"grandchild"]; }
        NSCAssert(request->invokeAfter == 0, @"Recovered forward dependency already completed");
        dispatch_async(engine.queue, ^{ copyRustDeliver(engine, identifier, NSData.data, 0); });
        return;
    }
    NSCAssert(!(request->flags & 128) && request->invokeAfter == 0, @"Copy RPCs do not delegate retries or depend on the failed forward");
    int32_t constructor = 0; [payload getBytes:&constructor length:4];
    id reply;
    @synchronized(engine.context) {
        [engine.context.payloads addObject:payload];
        NSMutableArray *replies = engine.context.replies[@(constructor).stringValue];
        reply = replies.firstObject;
        if (reply) [replies removeObjectAtIndex:0];
        if ([reply isKindOfClass:NSDictionary.class] && [reply[@"hold"] boolValue]) [engine.held addObject:@(identifier)];
    }
    if ([reply isKindOfClass:NSDictionary.class] && [reply[@"hold"] boolValue]) {
        dispatch_semaphore_signal(engine.context.pending);
        return;
    }
    dispatch_async(engine.queue, ^{
        copyRustDeliver(engine, identifier, [reply isKindOfClass:NSData.class] ? reply : (reply[@"error"] ?: @"TEST_UNEXPECTED_REQUEST"), 400);
    });
}
static void copyRustCancel(void *pointer, uint64_t session, uint64_t request) {
    CopyTestRustEngine *engine = (__bridge id)pointer;
    @synchronized(engine.context) {
        if ([engine.held containsObject:@(request)]) {
            [engine.held removeObject:@(request)];
            [engine.context.cancellations addObject:@(request)];
        }
    }
}
static void copyRustDestroy(void *pointer, uint64_t session) {
    CopyTestRustEngine *engine = (__bridge id)pointer;
    @synchronized(engine.context) {
        [engine.context.cancellations addObjectsFromArray:engine.held.allObjects];
        [engine.held removeAllObjects]; engine.destroyed = YES;
    }
}

static NSDictionary *runRustCopyScenario(NSDictionary *fixture, CopyTestContext *context) {
    // The reviewed runtime owns one process-lifetime engine. Keep test engines
    // alive too, so a later fixture cannot reuse a callback-context pointer.
    static NSMutableArray *engines;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ engines = [NSMutableArray new]; });
    CopyTestRustEngine *engine = [CopyTestRustEngine new];
    [engines addObject:engine]; engine.context = context; engine.fixture = fixture;
    engine.queue = dispatch_queue_create("TGExtra.TestRustFFI", DISPATCH_QUEUE_SERIAL);
    engine.completed = dispatch_semaphore_create(0); engine.initialGate = dispatch_semaphore_create(0);
    engine.held = [NSMutableSet new]; engine.sequence = [NSMutableArray new]; engine.counter = 10000;
    [TGExtraRustBridge setBufferData:copyRustData length:copyRustLength];
    [TGExtraRustBridge setCopyRequestID:copyRustNext send:copyRustSend cancel:copyRustCancel free:copyRustFree];
    void *native = [TGExtraRustBridge engineCreate:0 context:(__bridge void *)engine event:copyRustHostEvent log:NULL original:copyRustCreate];
    NSString *account = fixture[@"account"] ?: @"account-1";
    NSDictionary *usage = @{@"filePath": [NSString stringWithFormat:@"/accounts/%@/network-stats", account]};
    [TGExtraRustBridge usageManager:NULL selector:NULL info:(__bridge void *)usage original:copyRustUsage];
    if (![fixture[@"noContext"] boolValue])
        [TGExtraRustBridge authInfo:(__bridge void *)context selector:NULL datacenter:1 authSelector:0 original:copyRustAuth];
    uint64_t session = [TGExtraRustBridge sessionCreate:native setup:NULL original:copyRustSession];
    NSData *payload = fixture[@"payload"];
    TGERustRequest request = {8001, {payload.bytes, payload.length}, 0, 0, 0};
    [TGExtraRustBridge send:native session:session request:&request original:copyRustSend];
    if ([fixture[@"dependent"] boolValue] || [fixture[@"chain"] boolValue]) {
        uint32_t nearest = 0x1fb33026;
        TGERustRequest dependent = {9002, {(const uint8_t *)&nearest, 4}, 0, 0, 8001};
        [TGExtraRustBridge send:native session:session request:&dependent original:copyRustSend];
        if ([fixture[@"chain"] boolValue]) {
            TGERustRequest grandchild = {9003, {(const uint8_t *)&nearest, 4}, 0, 0, 9002};
            [TGExtraRustBridge send:native session:session request:&grandchild original:copyRustSend];
            NSCAssert(![engine.sequence containsObject:@"grandchild"], @"Dependencies on deferred requests stay deferred too");
        }
        NSCAssert(![engine.sequence containsObject:@"dependent"], @"Dependencies are held before the initial forward refusal");
        if ([fixture[@"cancelDependent"] boolValue])
            [TGExtraRustBridge cancel:native session:session request:9002 original:copyRustCancel];
    }
    dispatch_semaphore_signal(engine.initialGate);
    if ([fixture[@"cancel"] boolValue] || [fixture[@"destroy"] boolValue]) {
        NSCAssert(dispatch_semaphore_wait(context.pending, dispatch_time(DISPATCH_TIME_NOW, 5*NSEC_PER_SEC)) == 0, @"Rust copy reached a pending helper");
        if ([fixture[@"destroy"] boolValue]) [TGExtraRustBridge sessionDestroy:native session:session original:copyRustDestroy];
        else [TGExtraRustBridge cancel:native session:session request:8001 original:copyRustCancel];
    } else {
        NSCAssert(dispatch_semaphore_wait(engine.completed, dispatch_time(DISPATCH_TIME_NOW, 10*NSEC_PER_SEC)) == 0, @"Rust recovery completed without hanging");
    }
    TGExtraDrainCopyTestQueue();
    dispatch_sync(engine.queue, ^{});
    if (!engine.destroyed) [TGExtraRustBridge sessionDestroy:native session:session original:copyRustDestroy];
    TGExtraDrainCopyTestQueue();
    @synchronized(context) {
        return @{@"result": engine.result ?: NSData.data, @"error": engine.error ?: @"", @"completions": @(engine.completions),
            @"payloads": context.payloads.copy, @"cancellations": @(context.cancellations.count), @"sequence": engine.sequence.copy, @"activity": @(engine.activity)};
    }
}
