#import "PaidMedia.h"
#import "ForwardCopy.h"

@interface TGExtraMediaConnection : NSObject
- (instancetype)initWithContext:(id)context;
- (instancetype)initWithContext:(id)context datacenterId:(NSInteger)dc usageCalculationInfo:(id)usage
             requiredAuthToken:(id)token authTokenMasterDatacenterId:(NSInteger)master;
- (void)addMessageService:(id)service;
- (void)removeMessageService:(id)service;
- (void)resume;
- (void)stop;
- (bool)useTempAuthKeys;
- (void)setUseTempAuthKeys:(bool)value;
- (void)setMedia:(bool)value;
- (void)updateAuthTokenForDatacenterWithId:(NSInteger)dc authToken:(id)token;
- (void)authTokenForDatacenterWithIdRequired:(NSInteger)dc authToken:(id)token masterDatacenterId:(NSInteger)master;
@end

static dispatch_queue_t mediaQueue(void) {
    static dispatch_queue_t queue;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ queue = dispatch_queue_create("TGExtra.PaidMedia", DISPATCH_QUEUE_SERIAL); });
    return queue;
}

@interface TGExtraPaidMediaDownload : NSObject
@property(nonatomic, strong) TGExtraPaidMediaFile *media;
@property(nonatomic, copy) void (^completion)(NSURL *, NSError *);
@property(nonatomic, strong) TGExtraMediaConnection *network;
@property(nonatomic, strong) MTRequestMessageService *service;
@property(nonatomic, strong) MTRequest *pending;
@property(nonatomic, strong) NSFileHandle *output;
@property(nonatomic, strong) NSURL *url;
@property(nonatomic) int64_t offset;
@property(nonatomic) BOOL done;
- (void)start;
@end

@implementation TGExtraPaidMediaDownload
- (void)finish:(NSError *)error {
    if (self.done) return;
    self.done = YES;
    if (self.pending) [self.service removeRequestByInternalId:self.pending.internalId];
    self.pending.completed = nil;
    self.pending = nil;
    @try { [self.output closeFile]; }
    @catch (NSException *exception) {
        if (!error) error = [NSError errorWithDomain:@"TGExtra.PaidMedia" code:1 userInfo:nil];
    }
    self.output = nil;
    if (self.service) [self.network removeMessageService:self.service];
    [self.network stop];
    self.service = nil;
    self.network = nil;
    if (error) [NSFileManager.defaultManager removeItemAtURL:self.url error:NULL];
    void (^completion)(NSURL *, NSError *) = self.completion;
    self.completion = nil;
    NSURL *url = error ? nil : self.url;
    dispatch_async(dispatch_get_main_queue(), ^{ completion(url, error); });
}

- (void)fail {
    [self finish:[NSError errorWithDomain:@"TGExtra.PaidMedia" code:1 userInfo:nil]];
}

- (void)readChunk {
    NSData *payload = [self.media downloadRequestAtOffset:self.offset];
    if (!payload) { [self fail]; return; }
    MTRequest *request = [NSClassFromString(@"MTRequest") new];
    if (!request) { [self fail]; return; }
    [request setPayload:payload metadata:nil shortMetadata:@"TGExtra.paidMedia"
        responseParser:^id(NSData *bytes) { return bytes; }];
    request.needsTimeoutTimer = YES;
    request.shouldContinueExecutionWithErrorContext = ^bool(id context) { return false; };
    self.pending = request;
    __weak MTRequest *weakRequest = request;
    // The request keeps the operation alive until completion or timeout.
    request.completed = ^(id result, MTRequestResponseInfo *info, MTRpcError *error) {
        dispatch_async(mediaQueue(), ^{
            MTRequest *request = weakRequest;
            if (self.done || self.pending != request) return;
            self.pending = nil;
            request.completed = nil;
            NSData *bytes = !error && [result isKindOfClass:NSData.class]
                ? [TGExtraForwardCopyPlan fileBytesFromResponse:result] : nil;
            int64_t remaining = self.media.size > 0 ? self.media.size - self.offset : INT64_MAX;
            if (!bytes || bytes.length > 524288 || (int64_t)bytes.length > remaining ||
                (self.media.size > 0 && bytes.length != MIN((int64_t)524288, remaining))) {
                [self fail]; return;
            }
            @try { [self.output writeData:bytes]; }
            @catch (NSException *exception) { [self fail]; return; }
            self.offset += bytes.length;
            BOOL complete = self.media.size > 0 ? self.offset == self.media.size : bytes.length < 524288;
            if (complete) {
                if (self.offset == 0) [self fail];
                else [self finish:nil];
            } else { [self readChunk]; }
        });
    };
    [self.service addRequest:request];
    __weak TGExtraPaidMediaDownload *weakSelf = self;
    // Do not retain every completed chunk until its timeout expires.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 120 * NSEC_PER_SEC), mediaQueue(), ^{
        TGExtraPaidMediaDownload *op = weakSelf;
        MTRequest *pending = weakRequest;
        if (op && pending && !op.done && op.pending == pending) [op fail];
    });
}

- (void)start {
    self.url = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:
        [NSString stringWithFormat:@"TGExtraPaid-%@.%@", NSUUID.UUID.UUIDString, self.media.video ? @"mp4" : @"jpg"]]];
    // Only the complete MediaBox file is eligible; _partial can contain holes.
    if (self.media.cachePath) {
        NSDictionary *attributes = [NSFileManager.defaultManager attributesOfItemAtPath:self.media.cachePath error:NULL];
        int64_t size = [attributes[NSFileSize] longLongValue];
        if (size > 0 && (self.media.size == 0 || self.media.size == size) &&
            [NSFileManager.defaultManager copyItemAtPath:self.media.cachePath toPath:self.url.path error:NULL]) {
            [self finish:nil]; return;
        }
        [NSFileManager.defaultManager removeItemAtURL:self.url error:NULL];
    }
    SEL initializer = @selector(initWithContext:datacenterId:usageCalculationInfo:requiredAuthToken:authTokenMasterDatacenterId:);
    Class networkClass = NSClassFromString(@"MTProto"), serviceClass = NSClassFromString(@"MTRequestMessageService");
    if (![networkClass instancesRespondToSelector:initializer] ||
        ![serviceClass instancesRespondToSelector:@selector(initWithContext:)]) { [self fail]; return; }
    BOOL otherDC = self.media.datacenterId != self.media.masterDatacenterId;
    NSNumber *token = otherDC ? @(self.media.datacenterId) : nil;
    self.network = [(TGExtraMediaConnection *)[networkClass alloc] initWithContext:self.media.context
        datacenterId:self.media.datacenterId usageCalculationInfo:nil requiredAuthToken:token
        authTokenMasterDatacenterId:otherDC ? self.media.masterDatacenterId : 0];
    self.service = (id)[(TGExtraMediaConnection *)[serviceClass alloc] initWithContext:self.media.context];
    if (!self.network || !self.service) { [self fail]; return; }
    [self.network setUseTempAuthKeys:[(TGExtraMediaConnection *)self.media.context useTempAuthKeys]];
    [self.network setMedia:true];
    self.service.delegate = self;
    if (![NSFileManager.defaultManager createFileAtPath:self.url.path contents:nil attributes:nil] ||
        !(self.output = [NSFileHandle fileHandleForWritingAtPath:self.url.path])) { [self fail]; return; }
    [self.network addMessageService:self.service];
    [self.network resume];
    [self readChunk];
}

- (void)requestMessageServiceAuthorizationRequired:(MTRequestMessageService *)service {
    dispatch_async(mediaQueue(), ^{
        if (self.done || service != self.service || self.media.datacenterId == self.media.masterDatacenterId) return;
        TGExtraMediaConnection *context = (id)self.media.context;
        [context updateAuthTokenForDatacenterWithId:self.media.datacenterId authToken:nil];
        [context authTokenForDatacenterWithIdRequired:self.media.datacenterId
            authToken:@(self.media.datacenterId) masterDatacenterId:self.media.masterDatacenterId];
    });
}
@end

void TGExtraDownloadPaidMedia(TGExtraPaidMediaFile *file, void (^completion)(NSURL *, NSError *)) {
    TGExtraPaidMediaDownload *download = [TGExtraPaidMediaDownload new];
    download.media = file;
    download.completion = completion;
    dispatch_async(mediaQueue(), ^{ [download start]; });
}
