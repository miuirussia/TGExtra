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

@interface TGExtraPaidMediaFile ()
@property(nonatomic, readwrite) NSObject *context;
@property(nonatomic, readwrite) NSInteger masterDatacenterId;
@property(nonatomic, readwrite) NSInteger datacenterId;
@property(nonatomic, readwrite) int64_t size;
@property(nonatomic, readwrite) BOOL video;
@property(nonatomic, readwrite) NSString *cachePath;
@end
@implementation TGExtraPaidMediaFile
+ (instancetype)fileFromFooterNode:(id)footer { return nil; }
+ (BOOL)isUnlockedPaidItem:(id)item { return NO; }
+ (void)bindGalleryItem:(id)item {}
+ (id)contentNodeFromFooter:(id)footer { return nil; }
+ (id)footerNodeFromItem:(id)item { return nil; }
+ (double)bottomInsetFromFooter:(id)footer { return 0; }
- (NSData *)downloadRequestAtOffset:(int64_t)offset { return [NSData dataWithBytes:&offset length:8]; }
- (BOOL)beginNativeDownload {
    dispatch_assert_queue(dispatch_get_main_queue());
    if (!nativeSupported) return NO;
    nativeStarts++;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_MSEC * 50), dispatch_get_main_queue(), ^{
        [serverBytes writeToFile:self.cachePath atomically:YES];
        nativeReady = YES;
    });
    return YES;
}
- (NSNumber *)nativeDownloadProgress { dispatch_assert_queue(dispatch_get_main_queue()); return @0.5; }
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
@implementation MTRequestMessageService
- (instancetype)initWithContext:(id)context { NSCAssert(context == expectedContext, @"Service context"); return [super init]; }
- (void)addRequest:(MTRequest *)request {
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
        @synchronized(offsets) {
            activeRequests++;
            maximumRequests = MAX(maximumRequests, activeRequests);
        }
        void (^completed)(id, MTRequestResponseInfo *, MTRpcError *) = request.completed;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (offset == 0 ? 40 : 5) * NSEC_PER_MSEC), dispatch_get_global_queue(0, 0), ^{
            // Reproduce a transport that can still deliver a queued callback
            // after cancellation. Production must reject its retired token.
            @synchronized(offsets) { activeRequests--; [completedOffsets addObject:@(offset)]; }
            completed(response, nil, error);
        });
    } else { request.completed(response, nil, error); }
}
- (void)removeRequestByInternalId:(id)internalId { cancelledRequests++; }
- (void)removeRequestByInternalId:(id)internalId askForReconnectionOnDrop:(bool)ask {}
@end

static void runCase(NSUInteger index) {
    if (index == 12) { puts("PASS purchased-media download: native video fetch, partial cache, transport fallback, RPC errors, chunks and cleanup"); exit(0); }
    serverBytes = [NSMutableData dataWithLength:index == 1 ? 524288 : 524291];
    offsets = [NSMutableArray new];
    activeRequests = maximumRequests = cancelledRequests = 0;
    completedOffsets = [NSMutableArray new];
    reorderResponses = index >= 10;
    if (reorderResponses) {
        NSMutableData *bytes = [NSMutableData dataWithLength:7 * 524288 + 19];
        for (NSUInteger i = 0; i < bytes.length; i++) ((uint8_t *)bytes.mutableBytes)[i] = (uint8_t)(i / 524288 + i % 251);
        serverBytes = bytes;
    }
    stops = authRequests = 0;
    nativeStarts = 0;
    nativeReady = NO;
    nativeSupported = index == 7 || index == 8;
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
    if (index == 5 || index == 6 || index == 8) {
        file.cachePath = cache;
        NSData *data = index == 6 || index == 8 ? [NSData dataWithBytes:"bad" length:3] : serverBytes;
        [data writeToFile:cache atomically:YES];
    }
    if (index == 8) [serverBytes writeToFile:[cache stringByAppendingString:@"_partial"] atomically:YES];
    BOOL shouldFail = index == 3 || index == 4 || index == 11;
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
        else if (index == 7 || index == 8) {
            NSCAssert(nativeStarts == 1 && nativeReady && offsets.count == 0 && stops == 0,
                      @"Native full-file download finishes before export without a second MTProto session");
        }
        else if (index == 5) NSCAssert(offsets.count == 0 && stops == 0, @"Complete cache avoids a network session");
        else {
            NSCAssert(offsets.count == 2, @"Correct number of aligned chunks, including EOF for unknown size");
            NSCAssert(stops == 1 && authRequests == 1, @"Worker closes and requests the account's DC authorization");
        }
        for (NSString *name in [NSFileManager.defaultManager contentsOfDirectoryAtPath:NSTemporaryDirectory() error:NULL]) {
            NSCAssert(![name hasPrefix:@"TGExtraPaid-"], @"No failed download leaves a partial export behind");
        }
        [NSFileManager.defaultManager removeItemAtPath:cache error:NULL];
        [NSFileManager.defaultManager removeItemAtPath:[cache stringByAppendingString:@"_partial"] error:NULL];
        if (reorderResponses) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 60 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{ runCase(index + 1); });
        } else { runCase(index + 1); }
    });
}

int main(void) {
    @autoreleasepool {
        dispatch_async(dispatch_get_main_queue(), ^{ runCase(0); });
        dispatch_main();
    }
}
