#import "RustBridge.h"
#import "Headers.h"
#import "ForwardCopy.h"
#import <dlfcn.h>
#import <mach-o/loader.h>
#if __has_feature(ptrauth_calls)
#import <ptrauth.h>
#define TGE_IMPORT(pointer, type) ((type)ptrauth_sign_unauthenticated((pointer), ptrauth_key_function_pointer, 0))
#define TGE_EXPORT(pointer) ptrauth_strip((void *)(pointer), ptrauth_key_function_pointer)
#else
#define TGE_IMPORT(pointer, type) ((type)(pointer))
#define TGE_EXPORT(pointer) ((void *)(pointer))
#endif
typedef uint64_t (*TGESessionCreate)(void *, const void *);
typedef void (*TGESessionDestroy)(void *, uint64_t);
typedef void (*TGESend)(void *, uint64_t, const TGERustRequest *);
typedef void (*TGECancel)(void *, uint64_t, uint64_t);
typedef void (*TGEBufferFree)(void *);
typedef void *(*TGEUsageManager)(void *, void *, void *);
typedef void *(*TGEAuthInfo)(void *, void *, NSInteger, NSInteger);
typedef uint64_t (*TGENextRequestID)(void *);

@class TGERustRequestService;
@class TGERustEngine;

@interface TGERustPending : NSObject
@property NSData *payload;
@property NSData *fakeResponse;
@property NSData *wire;
@property TGERustRequest request;
@property BOOL guardsDependency;
@property BOOL deferred;
@property BOOL recovering;
@property MTRequest *recovery;
@end
@implementation TGERustPending
@end

@interface TGERustSession : NSObject
@property NSString *account;
@property NSMutableDictionary<NSNumber *, TGERustPending *> *requests;
@property TGERustRequestService *service;
@property uint64_t handle;
@end
@implementation TGERustSession
- (instancetype)init { if ((self = [super init])) _requests = [NSMutableDictionary new]; return self; }
@end

@interface TGERustEngine : NSObject
@property void *context;
@property TGERustEventCallback callback;
@property TGERustBufferData data;
@property TGERustBufferLength length;
@property TGEBufferFree freeBuffer;
@property TGENextRequestID nextRequestID;
@property TGESend send;
@property TGECancel cancel;
@property void *pointer;
@property NSMutableDictionary<NSNumber *, TGERustSession *> *sessions;
@end
@implementation TGERustEngine
- (instancetype)init { if ((self = [super init])) _sessions = [NSMutableDictionary new]; return self; }
@end

@interface TGERustConnection : NSObject
@property id context;
@property id usageCalculationInfo;
@property NSInteger datacenterId;
@end
@implementation TGERustConnection
@end

@interface TGERustRequestService : NSObject
@property TGERustConnection *mtProto;
@property(weak) TGERustEngine *engine;
@property(weak) TGERustSession *session;
@property NSMutableDictionary<NSNumber *, MTRequest *> *helpers;
@property NSMutableDictionary<id, NSNumber *> *identifiers;
- (void)addRequest:(MTRequest *)request;
- (void)removeRequestByInternalId:(id)internalId;
- (void)removeRequestByInternalId:(id)internalId askForReconnectionOnDrop:(bool)drop;
@end

static NSObject *bridgeLock;
static NSMutableDictionary<NSValue *, TGERustEngine *> *engines, *contexts;
static NSMutableDictionary<NSValue *, NSData *> *buffers;
static NSMutableSet<NSValue *> *syntheticBuffers;
static TGERustBufferData testData;
static TGERustBufferLength testLength;
static TGEBufferFree testFree;
static TGENextRequestID testNextRequestID;
static TGESend testSend;
static TGECancel testCancel;
static NSString *const pendingSessionKey = @"TGExtra.Rust.creatingSession";

static void initializeBridge(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        bridgeLock = [NSObject new]; engines = [NSMutableDictionary new];
        contexts = [NSMutableDictionary new]; buffers = [NSMutableDictionary new];
        syntheticBuffers = [NSMutableSet new];
    });
}
NSString *TGExtraRustCompatibilityStatus(void) {
    initializeBridge();
    @synchronized(bridgeLock) {
        if (engines.count) return [NSString stringWithFormat:@"active, %lu engine(s)", (unsigned long)engines.count];
    }
    NSString *path = [NSBundle.mainBundle pathForResource:@"TGExtraRustBridge" ofType:@"plist"];
    return path ? @"profile metadata present; no active engine observed" : @"no profile metadata or active engine; required for Rust transport";
}
static NSValue *pointerKey(const void *pointer) { return [NSValue valueWithPointer:pointer]; }

static void flushDependents(TGERustEngine *engine, TGERustSession *session, uint64_t completed) {
    @synchronized(bridgeLock) {
        if (engine.sessions[@(session.handle)] != session) return;
        for (TGERustPending *pending in session.requests.allValues) {
            if (!pending.deferred || pending.request.invokeAfter != completed) continue;
            pending.deferred = NO;
            TGERustRequest request = pending.request;
            request.invokeAfter = 0; // the prerequisite has already completed
            engine.send(engine.pointer, session.handle, &request);
        }
    }
}

@implementation TGERustRequestService
- (instancetype)init {
    if ((self = [super init])) { _helpers = [NSMutableDictionary new]; _identifiers = [NSMutableDictionary new]; }
    return self;
}
- (void)addRequest:(MTRequest *)request {
    @synchronized(bridgeLock) {
        TGERustEngine *engine = self.engine;
        TGERustSession *session = self.session;
        if (!session || engine.sessions[@(session.handle)] != session) return;
        uint64_t identifier = engine.nextRequestID(engine.pointer);
        if (!identifier) {
            MTRpcError *error = [[NSClassFromString(@"MTRpcError") alloc] initWithErrorCode:500 errorDescription:@"TGEXTRA_COPY_NETWORK_UNAVAILABLE"];
            request.completed(nil, nil, error);
            return;
        }
        self.helpers[@(identifier)] = request;
        self.identifiers[request.internalId] = @(identifier);
        TGERustRequest native = {0};
        native.id = identifier;
        native.body = (TGERustBytes){request.payload.bytes, request.payload.length};
        native.flags = (1 << 6) | (request.needsTimeoutTimer ? (1 << 5) : 0);
        engine.send(engine.pointer, session.handle, &native);
    }
}
- (void)removeRequestByInternalId:(id)internalId {
    @synchronized(bridgeLock) {
        NSNumber *identifier = self.identifiers[internalId];
        if (!identifier) return;
        [self.identifiers removeObjectForKey:internalId];
        [self.helpers removeObjectForKey:identifier];
        TGERustEngine *engine = self.engine;
        TGERustSession *session = self.session;
        if (session && engine.sessions[@(session.handle)] == session)
            engine.cancel(engine.pointer, session.handle, identifier.unsignedLongLongValue);
    }
}
- (void)removeRequestByInternalId:(id)internalId askForReconnectionOnDrop:(bool)drop {
    [self removeRequestByInternalId:internalId];
}
@end

static NSString *eventText(TGERustString value) {
    if (!value.data || !value.length) return @"RPC_ERROR";
    return [[NSString alloc] initWithBytes:value.data length:value.length encoding:NSUTF8StringEncoding] ?: @"RPC_ERROR";
}

static BOOL receiveHelper(TGERustEngine *engine, TGERustSession *session, const TGERustEvent *event) {
    MTRequest *request;
    @synchronized(bridgeLock) {
        request = session.service.helpers[@(event->requestId)];
        if (request && (event->kind == 1 || event->kind == 2 || event->kind == 36)) {
            [session.service.helpers removeObjectForKey:@(event->requestId)];
            [session.service.identifiers removeObjectForKey:request.internalId];
        }
    }
    if (!request) return NO;
    if (event->kind != 1 && event->kind != 2 && event->kind != 36) {
        if (event->kind != 3 && event->kind != 4 && event->kind != 5) return NO;
        engine.callback(engine.context, session.handle, event);
        return YES;
    }
    NSData *data;
    if (event->payload) {
        size_t length = engine.length(event->payload);
        const uint8_t *bytes = engine.data(event->payload);
        if (bytes || length == 0) data = [NSData dataWithBytes:bytes length:length];
        engine.freeBuffer(event->payload);
    }
    MTRpcError *error;
    if (event->kind != 1 || !data) {
        int32_t code = event->kind == 2 ? event->code : 500;
        NSString *reason = event->kind == 2 ? eventText(event->text) : event->kind == 36 ? @"ENGINE_SWITCHED" : @"TGEXTRA_COPY_RESPONSE_INVALID";
        error = [[NSClassFromString(@"MTRpcError") alloc] initWithErrorCode:code errorDescription:reason];
    }
    MTRequestResponseInfo *info = [[NSClassFromString(@"MTRequestResponseInfo") alloc]
        initWithNetworkType:0 timestamp:event->value1 duration:event->value2];
    TGERustEvent activity = *event;
    activity.payload = NULL;
    engine.callback(engine.context, session.handle, &activity);
    request.completed(error ? nil : request.responseParser(data), info, error);
    return YES;
}

static void completeRecovery(TGERustEngine *engine, TGERustSession *session, TGERustPending *pending,
    NSData *result, MTRequestResponseInfo *info, MTRpcError *error, double timestamp, double duration) {
    TGERustEvent event = {0};
    NSData *text;
    @synchronized(bridgeLock) {
        if (engine.sessions[@(session.handle)] != session || session.requests[@(pending.request.id)] != pending) return;
        [session.requests removeObjectForKey:@(pending.request.id)];
        pending.recovery = nil;
        event.requestId = pending.request.id;
        event.value1 = info ? info.timestamp : timestamp;
        event.value2 = info ? info.duration : duration;
        if (!error && result) {
            int32_t function = 0;
            [pending.payload getBytes:&function length:4];
            result = [TLParser handleResponse:result functionID:@(function) account:session.account requestPayload:pending.payload] ?: result;
            event.kind = 1;
            event.payload = malloc(1);
            if (event.payload) {
                NSValue *key = pointerKey(event.payload);
                buffers[key] = result;
                [syntheticBuffers addObject:key];
            } else {
                error = [[NSClassFromString(@"MTRpcError") alloc] initWithErrorCode:500 errorDescription:@"TGEXTRA_COPY_MEMORY_ERROR"];
            }
        }
        if (error || !result) {
            event.kind = 2;
            event.code = error ? error.errorCode : 500;
            text = [(error.errorDescription ?: @"TGEXTRA_COPY_RESPONSE_INVALID") dataUsingEncoding:NSUTF8StringEncoding];
            event.text = (TGERustString){text.bytes, text.length};
        }
    }
    engine.callback(engine.context, session.handle, &event);
    flushDependents(engine, session, event.requestId);
}

static BOOL beginRecovery(TGERustEngine *engine, TGERustSession *session,
    TGERustPending *pending, const TGERustEvent *event) {
    if (event->kind != 2 || !pending.guardsDependency || !session.service ||
        (event->code != 400 && event->code != 406) ||
        ![eventText(event->text) isEqualToString:@"CHAT_FORWARDS_RESTRICTED"]) return NO;
    @synchronized(bridgeLock) {
        if (session.requests[@(event->requestId)] != pending || pending.recovering) return NO;
        pending.recovering = YES;
        MTRpcError *error = [[NSClassFromString(@"MTRpcError") alloc] initWithErrorCode:event->code errorDescription:@"CHAT_FORWARDS_RESTRICTED"];
        MTRequestResponseInfo *info = [[NSClassFromString(@"MTRequestResponseInfo") alloc]
            initWithNetworkType:0 timestamp:event->value1 duration:event->value2];
        double timestamp = event->value1, duration = event->value2;
        __weak TGERustPending *weakPending = pending;
        pending.recovery = TGExtraRecoverForwardRequest(pending.payload, (id)session.service, info, error,
            ^(id result, MTRequestResponseInfo *replyInfo, MTRpcError *replyError) {
                TGERustPending *current = weakPending;
                if (current) completeRecovery(engine, session, current, [result isKindOfClass:NSData.class] ? result : nil,
                    replyInfo, replyError, timestamp, duration);
            });
        return pending.recovery != nil;
    }
}

static void receiveEvent(void *context, uint64_t handle, const TGERustEvent *event) {
    @autoreleasepool {
        TGERustEngine *engine;
        TGERustSession *session;
        TGERustPending *pending;
        @synchronized(bridgeLock) {
            engine = contexts[pointerKey(context)];
            session = engine.sessions[@(handle)];
            pending = session.requests[@(event->requestId)];
        }
        if (receiveHelper(engine, session, event)) return;
        if (pending && beginRecovery(engine, session, pending, event)) {
            if (event->payload) engine.freeBuffer(event->payload);
            return;
        }
        @synchronized(bridgeLock) {
            if (event->kind == 1 || event->kind == 2 || event->kind == 36)
                [session.requests removeObjectForKey:@(event->requestId)];
        }
        if (event->payload && (event->kind == 14 || (event->kind == 1 && pending))) {
            size_t length = engine.length(event->payload);
            const uint8_t *bytes = engine.data(event->payload);
            if (bytes && length >= 4) {
                NSData *data = [NSData dataWithBytes:bytes length:length];
                NSData *patched;
                if (event->kind == 14) {
                    patched = [TLParser stripAntiSelfDestruct:data account:session.account];
                } else if (pending.fakeResponse) {
                    patched = pending.fakeResponse;
                } else {
                    int32_t function = 0;
                    [pending.payload getBytes:&function length:4];
                    patched = [TLParser handleResponse:data functionID:@(function) account:session.account requestPayload:pending.payload];
                }
                if (patched) {
                    @synchronized(bridgeLock) { buffers[pointerKey(event->payload)] = patched; }
                }
            }
        }
        engine.callback(context, handle, event);
        if (pending && (event->kind == 1 || event->kind == 2 || event->kind == 36))
            flushDependents(engine, session, event->requestId);
    }
}

@implementation TGExtraRustBridge
+ (void *)engineCreate:(uint32_t)threads context:(void *)context event:(void *)event log:(void *)log original:(void *)rawOriginal {
    TGERustCreate original = TGE_IMPORT(rawOriginal, TGERustCreate);
    initializeBridge();
    TGERustBufferData data = testData;
    TGERustBufferLength length = testLength;
    TGEBufferFree freeBuffer = testFree;
    TGENextRequestID nextRequestID = testNextRequestID;
    TGESend send = testSend;
    TGECancel cancel = testCancel;
    if (!data || !length) {
        Dl_info image;
        if (!dladdr(rawOriginal, &image) || !image.dli_fbase) return original(threads, context, event, log);
        const struct mach_header_64 *header = image.dli_fbase;
        if (header->magic != MH_MAGIC_64 || header->cputype != CPU_TYPE_ARM64) return original(threads, context, event, log);
        const uint8_t *command = (const uint8_t *)(header + 1);
        NSData *uuid;
        uint64_t textSize = 0;
        for (uint32_t i = 0; i < header->ncmds; i++) {
            const struct load_command *load = (const void *)command;
            if (load->cmd == LC_UUID && load->cmdsize == sizeof(struct uuid_command))
                uuid = [NSData dataWithBytes:((const struct uuid_command *)load)->uuid length:16];
            if (load->cmd == LC_SEGMENT_64 && load->cmdsize >= sizeof(struct segment_command_64)) {
                const struct segment_command_64 *segment = (const void *)load;
                if (!strncmp(segment->segname, "__TEXT", 16) && segment->fileoff == 0) textSize = segment->filesize;
            }
            command += load->cmdsize;
        }
        NSString *path = [NSBundle.mainBundle pathForResource:@"TGExtraRustBridge" ofType:@"plist"];
        NSDictionary *config = path ? [NSDictionary dictionaryWithContentsOfFile:path] : nil;
        if ([config[@"ABI"] integerValue] != 5 || ![config[@"UUID"] isEqual:uuid]) return original(threads, context, event, log);
        uint64_t dataOffset = [config[@"BufferData"] unsignedLongLongValue];
        uint64_t lengthOffset = [config[@"BufferLength"] unsignedLongLongValue];
        if (textSize < 12 || dataOffset < 32 || lengthOffset < 32 || dataOffset > textSize - 12 || lengthOffset > textSize - 12)
            return original(threads, context, event, log);
        data = TGE_IMPORT((void *)((const uint8_t *)image.dli_fbase + dataOffset), TGERustBufferData);
        length = TGE_IMPORT((void *)((const uint8_t *)image.dli_fbase + lengthOffset), TGERustBufferLength);
        NSArray *names = @[@"BufferFree", @"NextRequestID", @"Send", @"Cancel"];
        uint64_t offsets[4] = {0};
        BOOL copyAvailable = YES;
        for (NSUInteger i = 0; i < names.count; i++) {
            offsets[i] = [config[names[i]] unsignedLongLongValue];
            if (offsets[i] < 32 || offsets[i] > textSize - 12) copyAvailable = NO;
        }
        if (copyAvailable) {
            const uint8_t *base = image.dli_fbase;
            freeBuffer = TGE_IMPORT((void *)(base + offsets[0]), TGEBufferFree);
            nextRequestID = TGE_IMPORT((void *)(base + offsets[1]), TGENextRequestID);
            send = TGE_IMPORT((void *)(base + offsets[2]), TGESend);
            cancel = TGE_IMPORT((void *)(base + offsets[3]), TGECancel);
        }
    }
    if (!event) return original(threads, context, event, log);
    TGERustEngine *state = [TGERustEngine new];
    state.freeBuffer = freeBuffer; state.nextRequestID = nextRequestID; state.send = send; state.cancel = cancel;
    state.context = context; state.callback = TGE_IMPORT(event, TGERustEventCallback); state.data = data; state.length = length;
    @synchronized(bridgeLock) {
        if (contexts[pointerKey(context)]) return original(threads, context, event, log);
        contexts[pointerKey(context)] = state;
    }
    void *engine = original(threads, context, TGE_EXPORT(receiveEvent), log);
    @synchronized(bridgeLock) {
        if (engine) { state.pointer = engine; engines[pointerKey(engine)] = state; }
        else [contexts removeObjectForKey:pointerKey(context)];
    }
    return engine;
}

+ (void *)usageManager:(void *)receiver selector:(void *)selector info:(void *)info original:(void *)rawOriginal {
    TGEUsageManager original = TGE_IMPORT(rawOriginal, TGEUsageManager);
    NSMutableDictionary *scope = [NSMutableDictionary new];
    if (info) scope[@"usage"] = (__bridge id)info;
    NSThread.currentThread.threadDictionary[pendingSessionKey] = scope;
    return original(receiver, selector, info);
}

+ (void *)authInfo:(void *)receiver selector:(void *)selector datacenter:(NSInteger)datacenter authSelector:(NSInteger)authSelector original:(void *)rawOriginal {
    TGEAuthInfo original = TGE_IMPORT(rawOriginal, TGEAuthInfo);
    NSMutableDictionary *scope = NSThread.currentThread.threadDictionary[pendingSessionKey];
    if (!scope) scope = [NSMutableDictionary new];
    if (receiver) scope[@"context"] = (__bridge id)receiver;
    scope[@"dc"] = @(datacenter);
    NSThread.currentThread.threadDictionary[pendingSessionKey] = scope;
    return original(receiver, selector, datacenter, authSelector);
}

+ (uint64_t)sessionCreate:(void *)engine setup:(const void *)setup original:(void *)rawOriginal {
    TGESessionCreate original = TGE_IMPORT(rawOriginal, TGESessionCreate);
    NSDictionary *scope = NSThread.currentThread.threadDictionary[pendingSessionKey];
    [NSThread.currentThread.threadDictionary removeObjectForKey:pendingSessionKey];
    NSString *account;
    @try { account = TGExtraHistoryAccountForPath([scope[@"usage"] valueForKey:@"filePath"]); }
    @catch (NSException *exception) { account = nil; }
    uint64_t handle = original(engine, setup);
    if (handle) {
        TGERustSession *state = [TGERustSession new]; state.account = account; state.handle = handle;
        @synchronized(bridgeLock) {
            TGERustEngine *owner = engines[pointerKey(engine)];
            if (account && scope[@"context"] && [scope[@"dc"] integerValue] > 0 &&
                owner.send && owner.cancel && owner.nextRequestID && owner.freeBuffer) {
                TGERustRequestService *service = [TGERustRequestService new];
                service.engine = owner; service.session = state;
                TGERustConnection *connection = [TGERustConnection new];
                connection.context = scope[@"context"]; connection.usageCalculationInfo = scope[@"usage"];
                connection.datacenterId = [scope[@"dc"] integerValue]; service.mtProto = connection;
                state.service = service;
            }
            owner.sessions[@(handle)] = state;
        }
    }
    return handle;
}

+ (void)sessionDestroy:(void *)engine session:(uint64_t)session original:(void *)rawOriginal {
    TGESessionDestroy original = TGE_IMPORT(rawOriginal, TGESessionDestroy);
    @synchronized(bridgeLock) {
        TGERustEngine *owner = engines[pointerKey(engine)];
        TGERustSession *state = owner.sessions[@(session)];
        for (TGERustPending *pending in state.requests.allValues) {
            if (pending.recovery) TGExtraCancelForwardRequest(pending.recovery.internalId, (id)state.service);
        }
        [owner.sessions removeObjectForKey:@(session)];
        [state.requests removeAllObjects];
        [state.service.helpers removeAllObjects]; [state.service.identifiers removeAllObjects];
        original(engine, session);
    }
}

+ (void)send:(void *)engine session:(uint64_t)session request:(const TGERustRequest *)request original:(void *)rawOriginal {
    TGESend original = TGE_IMPORT(rawOriginal, TGESend);
    @synchronized(bridgeLock) {
        TGERustEngine *owner = engines[pointerKey(engine)];
        TGERustSession *state = owner.sessions[@(session)];
        if (!state || !request || !request->body.data || request->body.length < 4) {
            original(engine, session, request); return;
        }
        NSData *payload = [NSData dataWithBytes:request->body.data length:request->body.length];
        TGERustPending *pending = [TGERustPending new];
        pending.payload = TGExtraRewriteRequestPayload(payload);
        pending.fakeResponse = TGExtraFakeResponseForPayload(pending.payload);
        NSDictionary *contentPolicy = [TLParser readMessageContentsPolicy:pending.payload account:state.account];
        if (contentPolicy[@"payload"]) pending.payload = contentPolicy[@"payload"];
        if (contentPolicy[@"response"]) pending.fakeResponse = contentPolicy[@"response"];
        pending.guardsDependency = [TLParser isForwardRequest:pending.payload] && state.service &&
            [NSUserDefaults.standardUserDefaults boolForKey:kDisableForwardRestriction];
        NSData *replacement = pending.fakeResponse ? [TLParser privacyReplacementRequest] : nil;
        if (pending.fakeResponse && !replacement) pending.fakeResponse = nil;
        pending.wire = replacement ?: pending.payload;
        TGERustRequest rewritten = *request;
        rewritten.body = (TGERustBytes){pending.wire.bytes, pending.wire.length};
        pending.request = rewritten;
        state.requests[@(request->id)] = pending;
        TGERustPending *dependency = state.requests[@(request->invokeAfter)];
        if (dependency.guardsDependency || dependency.deferred) {
            pending.deferred = YES;
        } else {
            original(engine, session, &rewritten);
        }
    }
}

+ (void)cancel:(void *)engine session:(uint64_t)session request:(uint64_t)request original:(void *)rawOriginal {
    TGECancel original = TGE_IMPORT(rawOriginal, TGECancel);
    TGERustEngine *owner;
    TGERustSession *state;
    @synchronized(bridgeLock) {
        owner = engines[pointerKey(engine)]; state = owner.sessions[@(session)];
        TGERustPending *pending = state.requests[@(request)];
        if (pending.recovery) TGExtraCancelForwardRequest(pending.recovery.internalId, (id)state.service);
        [state.requests removeObjectForKey:@(request)];
        original(engine, session, request);
    }
    flushDependents(owner, state, request);
}

+ (const uint8_t *)bufferData:(const void *)buffer original:(void *)rawOriginal {
    TGERustBufferData original = TGE_IMPORT(rawOriginal, TGERustBufferData);
    NSData *data;
    @synchronized(bridgeLock) { data = buffers[pointerKey(buffer)]; }
    return data ? data.bytes : original(buffer);
}
+ (size_t)bufferLength:(const void *)buffer original:(void *)rawOriginal {
    TGERustBufferLength original = TGE_IMPORT(rawOriginal, TGERustBufferLength);
    NSData *data;
    @synchronized(bridgeLock) { data = buffers[pointerKey(buffer)]; }
    return data ? data.length : original(buffer);
}
+ (void)bufferFree:(void *)buffer original:(void *)rawOriginal {
    TGEBufferFree original = TGE_IMPORT(rawOriginal, TGEBufferFree);
    BOOL synthetic;
    @synchronized(bridgeLock) {
        NSValue *key = pointerKey(buffer);
        synthetic = [syntheticBuffers containsObject:key];
        [buffers removeObjectForKey:key]; [syntheticBuffers removeObject:key];
    }
    if (synthetic) free(buffer);
    else original(buffer);
}
#ifdef TGEXTRA_TESTING
+ (void)setBufferData:(TGERustBufferData)data length:(TGERustBufferLength)length {
    initializeBridge(); testData = data; testLength = length;
}
+ (void)setCopyRequestID:(void *)next send:(void *)send cancel:(void *)cancel free:(void *)free {
    testNextRequestID = TGE_IMPORT(next, TGENextRequestID); testSend = TGE_IMPORT(send, TGESend);
    testCancel = TGE_IMPORT(cancel, TGECancel); testFree = TGE_IMPORT(free, TGEBufferFree);
}
#endif
@end
