#import "Support/RequestFixtures.h"
#import "../Sources/tgapi/RustBridge.h"
#import "../Sources/tgapi/Headers.h"

static TGERustEventCallback eventCallback;
static void *callbackContext;
static void *testEngine;
static NSData *sent, *received;
static uint64_t sentId, sentAfter, nextSession;
static uint32_t sentFlags, sentExpected;
static NSUInteger freeCount, callbackCount, cancelCount, destroyCount;

static const uint8_t *rawData(const void *buffer) { return [(__bridge NSData *)buffer bytes]; }
static size_t rawLength(const void *buffer) { return [(__bridge NSData *)buffer length]; }
static void rawFree(void *buffer) { freeCount++; }
static void hostEvent(void *context, uint64_t session, const TGERustEvent *event) {
    NSCAssert(context == callbackContext, @"The host context must stay intact for stream/log callbacks too");
    callbackCount++;
    if (event->payload) {
        size_t length = [TGExtraRustBridge bufferLength:event->payload original:rawLength];
        const uint8_t *bytes = [TGExtraRustBridge bufferData:event->payload original:rawData];
        received = [NSData dataWithBytes:bytes length:length];
    }
}
static void *createEngine(uint32_t threads, void *context, TGERustEventCallback event, TGERustLogCallback log) {
    NSCAssert(context == callbackContext, @"Do not wrap the shared callback context");
    eventCallback = event;
    return (void *)0x12345;
}
static uint64_t createSession(void *engine, const void *setup) { return ++nextSession; }
static void destroySession(void *engine, uint64_t session) { destroyCount++; }
static void sendRequest(void *engine, uint64_t session, const TGERustRequest *request) {
    sent = [NSData dataWithBytes:request->body.data length:request->body.length];
    sentId = request->id; sentFlags = request->flags;
    sentExpected = request->expectedResponseSize; sentAfter = request->invokeAfter;
}
static void cancelRequest(void *engine, uint64_t session, uint64_t request) { cancelCount++; }
static void *usageManager(void *receiver, void *selector, void *info) { return receiver; }
static void emit(uint64_t session, uint32_t kind, uint64_t request, NSData *data) {
    TGERustEvent event = {0};
    event.kind = kind; event.requestId = request; event.payload = (__bridge void *)data;
    event.value1 = 123; event.value2 = 0.5;
    eventCallback(callbackContext, session, &event);
}

@interface RustTestUsage : NSObject
@property NSString *filePath;
@end
@implementation RustTestUsage
@end
static uint64_t scopedSession(void *engine, NSString *path) {
    RustTestUsage *usage = [RustTestUsage new]; usage.filePath = path;
    [TGExtraRustBridge usageManager:NULL selector:NULL info:(__bridge void *)usage original:usageManager];
    return [TGExtraRustBridge sessionCreate:engine setup:NULL original:createSession];
}

NSDictionary *TGExtraTestRustReadContentsRequest(NSData *payload, NSString *account, NSData *serverResponse) {
    // Reuse the registered engine: a duplicate callback context intentionally
    // bypasses the bridge and would test the raw mock instead of its policy.
    void *engine = testEngine;
    NSCAssert(engine != NULL, @"The Rust bridge fixture must be initialized first");
    uint64_t session = scopedSession(engine, account ? [NSString stringWithFormat:@"/accounts/%@/network-stats", account] : nil);
    TGERustRequest request = {700, {payload.bytes, payload.length}, 0x89, 1024, 17};
    [TGExtraRustBridge send:engine session:session request:&request original:sendRequest];
    NSCAssert(sentId == 700 && sentFlags == 0x89 && sentExpected == 1024 && sentAfter == 17, @"Content filtering preserves Rust scheduling metadata");
    NSData *wire = sent;
    emit(session, 1, 700, serverResponse);
    NSData *result = received;
    [TGExtraRustBridge bufferFree:(__bridge void *)serverResponse original:rawFree];
    [TGExtraRustBridge sessionDestroy:engine session:session original:destroySession];
    return @{@"payload": wire, @"response": result};
}

void TGExtraTestRustBridge(void) {
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    NSDictionary *saved = defaults.dictionaryRepresentation;
    [defaults setBool:YES forKey:kGhostModeEnabled];
    [defaults setBool:YES forKey:kDisableOnlineStatus];
    [TGExtraRustBridge setBufferData:rawData length:rawLength];
    callbackContext = (void *)0x6789;
    void *engine = [TGExtraRustBridge engineCreate:0 context:callbackContext event:hostEvent log:NULL original:createEngine];
    testEngine = engine;
    uint64_t session = [TGExtraRustBridge sessionCreate:engine setup:NULL original:createSession];
    uint32_t online[] = {(uint32_t)kAccountUpdateOnlineStatus, 0xbc799737};
    TGERustRequest request = {41, {(const uint8_t *)online, sizeof(online)}, 0x89, 1024, 17};
    [TGExtraRustBridge send:engine session:session request:&request original:sendRequest];
    uint32_t function;
    [sent getBytes:&function length:4];
    NSCAssert(function == 0x1fb33026 && sent.length == 4, @"Online activity must be replaced before Rust copies the request");
    NSCAssert(sentId == 41 && sentFlags == 0x89 && sentExpected == 1024 && sentAfter == 17, @"Preserve request IDs, dependencies, flags and sizing");
    NSCAssert(callbackCount == 0, @"Do not complete a request synchronously from send");
    uint32_t raw[] = {0x8e1a1775, 9};
    NSData *response = [NSData dataWithBytes:raw length:sizeof(raw)];
    // Retry decisions are not terminal and must retain the request policy.
    emit(session, 27, 41, nil);
    emit(session, 1, 41, response);
    [received getBytes:&function length:4];
    NSCAssert(received.length == 4 && function == 0x997275b5, @"A successful harmless RPC supplies the expected synthetic response");
    NSCAssert([TGExtraRustBridge bufferLength:(__bridge void *)response original:rawLength] == 4, @"Replacement bytes survive the callback for Swift's no-copy Data");
    [TGExtraRustBridge bufferFree:(__bridge void *)response original:rawFree];
    NSCAssert(freeCount == 1 && [TGExtraRustBridge bufferLength:(__bridge void *)response original:rawLength] == response.length, @"Free the Rust buffer once and release the replacement");

    request.id = 42;
    [TGExtraRustBridge send:engine session:session request:&request original:sendRequest];
    [TGExtraRustBridge cancel:engine session:session request:42 original:cancelRequest];
    emit(session, 1, 42, response);
    NSCAssert([received isEqual:response] && cancelCount == 1, @"Late canceled responses cannot run the response policy");
    request.id = 43;
    [TGExtraRustBridge send:engine session:session request:&request original:sendRequest];
    emit(session, 2, 43, nil);
    emit(session, 1, 43, response);
    NSCAssert([received isEqual:response], @"Real failures stay failures and release pending request state");
    request.id = 44;
    [TGExtraRustBridge send:engine session:session request:&request original:sendRequest];
    emit(session, 36, 44, nil);
    emit(session, 1, 44, response);
    NSCAssert([received isEqual:response], @"Drained requests release their old session binding");

    // Secret/key material must never enter the TL codec even if its bytes happen
    // to begin with an API constructor.
    emit(session, 21, 0, response);
    NSCAssert([received isEqual:response], @"Auth-key events pass through byte-for-byte");
    [defaults setBool:NO forKey:kGhostModeEnabled];
    request.id = 45;
    [TGExtraRustBridge send:engine session:session request:&request original:sendRequest];
    NSCAssert([sent isEqual:[NSData dataWithBytes:online length:sizeof(online)]], @"Disabled policy leaves outgoing payload intact");
    [TGExtraRustBridge sessionDestroy:engine session:session original:destroySession];
    [TGExtraRustBridge send:engine session:session request:&request original:sendRequest];
    NSCAssert(destroyCount == 1, @"Destroy the original session and remove its policy state");

    [defaults setBool:YES forKey:kAntiRevoke];
    uint64_t first = scopedSession(engine, @"/accounts/account-112233/network-stats");
    uint64_t second = scopedSession(engine, @"/accounts/account-445566/network-stats");
    uint64_t unknown = [TGExtraRustBridge sessionCreate:engine setup:NULL original:createSession];
    uint32_t deletion[] = {0x78d4dec1, 0xa20db0e5, 0x1cb5c415, 1, 770077, 1, 1, 123};
    NSData *update = [NSData dataWithBytes:deletion length:sizeof(deletion)];
    emit(first, 14, 0, update);
    NSCAssert(![received isEqual:update], @"Live Rust updates run through Anti-Revoke");
    NSCAssert([TLParser isDeleted:@770077 peer:@123 account:@"account-112233" messageNamespace:@0], @"Live updates bind to their session account");
    NSCAssert(![TLParser isDeleted:@770077 peer:@123 account:@"account-445566" messageNamespace:@0], @"Other accounts do not inherit deletion markers");
    [TGExtraRustBridge bufferFree:(__bridge void *)update original:rawFree];
    emit(unknown, 14, 0, update);
    NSCAssert(![TLParser isDeleted:@770077 peer:@123 account:@"account-445566" messageNamespace:@0], @"A session without usage info cannot borrow the previous account");
    [TGExtraRustBridge bufferFree:(__bridge void *)update original:rawFree];
    uint32_t nearest = 0x1fb33026;
    request = (TGERustRequest){99, {(const uint8_t *)&nearest, 4}, 0, 0, 0};
    [TGExtraRustBridge send:engine session:second request:&request original:sendRequest];
    emit(second, 1, 99, update);
    NSCAssert([TLParser isDeleted:@770077 peer:@123 account:@"account-445566" messageNamespace:@0], @"RPC responses use the request session account too");
    [TGExtraRustBridge bufferFree:(__bridge void *)update original:rawFree];
    [TGExtraRustBridge sessionDestroy:engine session:first original:destroySession];
    [TGExtraRustBridge sessionDestroy:engine session:second original:destroySession];
    [TGExtraRustBridge sessionDestroy:engine session:unknown original:destroySession];
    [TLParser clearMessageData];
    request = (TGERustRequest){100, {(const uint8_t *)online, sizeof(online)}, 0, 0, 0};

    // Explicitly untracked engines pass through, even with ghost mode enabled.
    [defaults setBool:YES forKey:kGhostModeEnabled];
    [TGExtraRustBridge send:(void *)0xdead session:1 request:&request original:sendRequest];
    NSCAssert(sent.length == sizeof(online), @"Do not patch an engine whose ABI was not registered");
    for (NSString *key in defaults.dictionaryRepresentation) [defaults removeObjectForKey:key];
    for (NSString *key in saved) [defaults setObject:saved[key] forKey:key];
    puts("PASS Rust FFI request policy, scheduling metadata, callbacks, no-copy buffer lifetime, account isolation, push/RPC updates and cancellation");
}
