#import "../Sources/tgapi/PaidMedia.h"
#import "../Sources/tgapi/Headers.h"

static NSData *serverBytes;
static NSMutableArray<NSNumber *> *offsets;
static BOOL truncateResponse, serverError;
static NSUInteger stops, authRequests;
static id expectedContext;
static BOOL nativeSupported, nativeReady;
static NSUInteger nativeStarts;
static NSUInteger activeRequests, maximumRequests, cancelledRequests;
static NSMutableArray<NSNumber *> *completedOffsets;
static BOOL reorderResponses;
static NSMutableDictionary<NSNumber *, id> *pendingReplies;
static NSURL *downloadURL;

@interface TGExtraPaidMediaFile ()
@property(nonatomic, readwrite) NSObject *context;
@property(nonatomic, readwrite) NSInteger masterDatacenterId;
@property(nonatomic, readwrite) NSInteger datacenterId;
@property(nonatomic, readwrite) int64_t size;
@property(nonatomic, readwrite) BOOL video;
@property(nonatomic, readwrite) BOOL nativeOnly;
@property(nonatomic, readwrite) NSString *cachePath;
@end
@implementation TGExtraPaidMediaFile
+ (instancetype)fileFromFooterNode:(id)footer { return nil; }
+ (BOOL)isUnlockedPaidItem:(id)item { return NO; }
+ (void)bindGalleryItem:(id)item {}
+ (id)currentFooterNodeFromGalleryFooter:(id)container { return nil; }
+ (id)footerNodeFromItem:(id)item { return nil; }
- (NSData *)downloadRequestAtOffset:(int64_t)offset { return [NSData dataWithBytes:&offset length:8]; }
- (BOOL)beginNativeDownload {
    dispatch_assert_queue(dispatch_get_main_queue());
    if (!nativeSupported) return NO;
    nativeStarts++;
    return YES;
}
- (NSNumber *)nativeDownloadProgress {
    dispatch_assert_queue(dispatch_get_main_queue());
    NSCAssert(nativeStarts == 1, @"Progress is queried only after starting the native fetch");
    if (!nativeReady) {
        // Publish the completed native file only after the downloader begins waiting for progress.
        [serverBytes writeToFile:self.cachePath atomically:YES];
        nativeReady = YES;
    }
    return @0.5;
}
@end

// The Swift codec has separate wire-level tests; this harness exercises the
// production downloader's chunk boundaries, lifetime, failures and disk I/O.
@interface TGExtraForwardCopyPlan : NSObject
+ (NSData *)fileBytesFromResponse:(NSData *)response;
@end
@implementation TGExtraForwardCopyPlan
+ (NSData *)fileBytesFromResponse:(NSData *)response { return response; }
@end

@interface MTRequest ()
@property(nonatomic, strong, readwrite) id internalId;
@property(nonatomic, strong, readwrite) id (^responseParser)(NSData *);
@end
@implementation MTRequest
- (instancetype)init { if ((self = [super init])) self.internalId = NSUUID.UUID; return self; }
- (void)setPayload:(NSData *)payload metadata:(id)metadata shortMetadata:(id)shortMetadata responseParser:(id (^)(NSData *))parser {
    self.payload = payload; self.responseParser = parser;
}
@end
@implementation MTRpcError
- (instancetype)initWithErrorCode:(int)code errorDescription:(NSString *)description {
    if ((self = [super init])) { _errorCode = code; _errorDescription = description; }
    return self;
}
@end

@interface TestMediaContext : NSObject
- (bool)useTempAuthKeys;
- (void)updateAuthTokenForDatacenterWithId:(NSInteger)dc authToken:(id)token;
- (void)authTokenForDatacenterWithIdRequired:(NSInteger)dc authToken:(id)token masterDatacenterId:(NSInteger)master;
@end
@implementation TestMediaContext
- (bool)useTempAuthKeys { return false; }
- (void)updateAuthTokenForDatacenterWithId:(NSInteger)dc authToken:(id)token {}
- (void)authTokenForDatacenterWithIdRequired:(NSInteger)dc authToken:(id)token masterDatacenterId:(NSInteger)master {
    NSCAssert(dc == 4 && master == 2 && [token isEqual:@4], @"Authorization belongs to the file and account DCs");
    authRequests++;
}
@end

@interface MTProto : NSObject
- (instancetype)initWithContext:(id)context datacenterId:(NSInteger)dc usageCalculationInfo:(id)usage
             requiredAuthToken:(id)token authTokenMasterDatacenterId:(NSInteger)master;
- (void)addMessageService:(id)service;
- (void)removeMessageService:(id)service;
- (void)resume;
- (void)stop;
- (void)setUseTempAuthKeys:(bool)value;
- (void)setMedia:(bool)value;
@end
@implementation MTProto
- (instancetype)initWithContext:(id)context datacenterId:(NSInteger)dc usageCalculationInfo:(id)usage
             requiredAuthToken:(id)token authTokenMasterDatacenterId:(NSInteger)master {
    NSCAssert(context == expectedContext && dc == 4 && master == 2 && [token isEqual:@4], @"Owning account context and remote DC");
    return [super init];
}
- (void)addMessageService:(id)service {}
- (void)removeMessageService:(id)service {}
- (void)resume {}
- (void)stop { stops++; }
- (void)setUseTempAuthKeys:(bool)value {}
- (void)setMedia:(bool)value { NSCAssert(value, @"Worker is a media session"); }
@end

@interface NSObject (TestMediaAuthorization)
- (void)requestMessageServiceAuthorizationRequired:(id)service;
@end
@interface MTRequestMessageService (TestMediaInitializer)
- (instancetype)initWithContext:(id)context;
@end
static void deliverReply(NSNumber *offset) {
    dispatch_block_t reply = pendingReplies[offset];
    NSCAssert(reply, @"Each queued response is delivered exactly once");
    [pendingReplies removeObjectForKey:offset];
    activeRequests--;
    [completedOffsets addObject:offset];
    reply();
}

@implementation MTRequestMessageService
- (instancetype)initWithContext:(id)context { NSCAssert(context == expectedContext, @"Service context"); return [super init]; }
- (void)addRequest:(MTRequest *)request {
    downloadURL = [self.delegate valueForKey:@"url"];
    int64_t offset = 0;
    [request.payload getBytes:&offset length:8];
    NSCAssert(offset >= 0 && offset <= (int64_t)serverBytes.length, @"No requests past EOF");
    if (offsets.count == 0) [self.delegate requestMessageServiceAuthorizationRequired:self];
    [offsets addObject:@(offset)];
    NSUInteger length = MIN(524288, serverBytes.length - offset);
    if (truncateResponse && length) length--;
    NSData *response = [serverBytes subdataWithRange:NSMakeRange(offset, length)];
    MTRpcError *error = serverError ? [[MTRpcError alloc] initWithErrorCode:400 errorDescription:@"FILE_REFERENCE_EXPIRED"] : nil;
    if (reorderResponses) {
        activeRequests++;
        maximumRequests = MAX(maximumRequests, activeRequests);
        void (^completed)(id, MTRequestResponseInfo *, MTRpcError *) = request.completed;
        dispatch_block_t reply = ^{ completed(response, nil, error); };
        pendingReplies[@(offset)] = [reply copy];
        if (offsets.count == 4) {
            if (serverError) {
                deliverReply(@524288);
            } else {
                // Fill the window, then deliver its replies in reverse order, keeping the first pending.
                for (int64_t chunk = 3; chunk > 0; chunk--) deliverReply(@(chunk * 524288));
            }
        } else if (offsets.count > 4) {
            deliverReply(@(offset));
            if (offsets.count == (serverBytes.length + 524287) / 524288) deliverReply(@0);
        }
    } else { request.completed(response, nil, error); }
}
- (void)removeRequestByInternalId:(id)internalId {
    cancelledRequests++;
    if (reorderResponses && serverError && cancelledRequests == 3) {
        // The transport already captured these callbacks before cancellation.
        // Deliver them after every remaining request has been cancelled.
        for (NSNumber *offset in pendingReplies.allKeys) deliverReply(offset);
    }
}
- (void)removeRequestByInternalId:(id)internalId askForReconnectionOnDrop:(bool)ask {}
@end

static void runCase(NSUInteger index) {
    NSCAssert(activeRequests == 0 && pendingReplies.count == 0,
              @"Previous transport callbacks finish before advancing or exiting");
    if (index == 16) { puts("PASS media download: paid transport, secret plaintext cache, native fetch, no encrypted fallback, chunks and cleanup"); exit(0); }
    serverBytes = [NSMutableData dataWithLength:index == 1 ? 524288 : 524291];
    offsets = [NSMutableArray new];
    activeRequests = maximumRequests = cancelledRequests = 0;
    completedOffsets = [NSMutableArray new];
    pendingReplies = [NSMutableDictionary new];
    downloadURL = nil;
    reorderResponses = index == 10 || index == 11;
    if (reorderResponses) {
        NSMutableData *bytes = [NSMutableData dataWithLength:7 * 524288 + 19];
        for (NSUInteger i = 0; i < bytes.length; i++) ((uint8_t *)bytes.mutableBytes)[i] = (uint8_t)(i / 524288 + i % 251);
        serverBytes = bytes;
    }
    stops = authRequests = 0;
    nativeStarts = 0;
    nativeReady = NO;
    nativeSupported = index == 7 || index == 8 || index == 12 || index == 13;
    truncateResponse = index == 3;
    serverError = index == 4 || index == 11;
    TGExtraPaidMediaFile *file = [TGExtraPaidMediaFile new];
    file.context = [TestMediaContext new];
    expectedContext = file.context;
    file.masterDatacenterId = 2; file.datacenterId = 4;
    file.size = index == 1 || index == 2 ? 0 : serverBytes.length;
    NSString *cache = [NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
    if (index >= 7 && index < 10) {
        file.video = YES;
        file.cachePath = cache;
    }
    if (index >= 12) {
        file.nativeOnly = YES;
        file.video = index == 13;
        file.cachePath = cache;
    }
    if (index == 5 || index == 6 || index == 8) {
        file.cachePath = cache;
        NSData *data = index == 6 || index == 8 ? [NSData dataWithBytes:"bad" length:3] : serverBytes;
        [data writeToFile:cache atomically:YES];
    }
    if (index == 8) [serverBytes writeToFile:[cache stringByAppendingString:@"_partial"] atomically:YES];
    if (index == 14) [serverBytes writeToFile:cache atomically:YES];
    if (index == 15) {
        // An encrypted container or incomplete cache must never be exported.
        [[NSData dataWithBytes:"encrypted-container" length:19] writeToFile:cache atomically:YES];
    }
    BOOL shouldFail = index == 3 || index == 4 || index == 11 || index == 15;
    TGExtraDownloadPaidMedia(file, ^(NSURL *url, NSError *error) {
        dispatch_assert_queue(dispatch_get_main_queue());
        NSCAssert(shouldFail ? (!url && error) : (url && !error), @"Completion reflects download failure");
        if (index == 4) NSCAssert(error.code == 400 && [error.localizedDescription isEqual:@"FILE_REFERENCE_EXPIRED"],
                                  @"Original RPC failure remains available for diagnosis");
        if (!shouldFail) {
            NSCAssert([[NSData dataWithContentsOfURL:url] isEqual:serverBytes], @"Export is byte-identical and alive after completion");
            [NSFileManager.defaultManager removeItemAtURL:url error:NULL];
        }
        if (reorderResponses) {
            NSCAssert(maximumRequests == 4, @"Issue a bounded window before waiting for the first reply");
            if (!shouldFail) NSCAssert(completedOffsets.firstObject.longLongValue != 0, @"Exercise out-of-order file writes");
            NSCAssert(offsets.count == (shouldFail ? 4 : 8), @"Parallel reads cover the file exactly once");
            if (shouldFail) NSCAssert(cancelledRequests == 3, @"An error cancels every other active chunk");
        }
        else if (index == 7 || index == 8 || index == 12 || index == 13) {
            NSCAssert(nativeStarts == 1 && nativeReady && offsets.count == 0 && stops == 0,
                      @"Native full-file download finishes before export without a second MTProto session");
        }
        else if (index == 5 || index == 14 || index == 15) NSCAssert(offsets.count == 0 && stops == 0, @"Secret cache paths never fall back to a cloud network session");
        else {
            NSCAssert(offsets.count == 2, @"Correct number of aligned chunks, including EOF for unknown size");
            NSCAssert(stops == 1 && authRequests == 1, @"Worker closes and requests the account's DC authorization");
        }
        if (shouldFail && index != 15) {
            NSCAssert(downloadURL && ![NSFileManager.defaultManager fileExistsAtPath:downloadURL.path],
                      @"A failed download removes its own partial export");
        }
        [NSFileManager.defaultManager removeItemAtPath:cache error:NULL];
        [NSFileManager.defaultManager removeItemAtPath:[cache stringByAppendingString:@"_partial"] error:NULL];
        runCase(index + 1);
    });
}

int main(void) {
    @autoreleasepool {
        dispatch_async(dispatch_get_main_queue(), ^{ runCase(0); });
        dispatch_main();
    }
}
