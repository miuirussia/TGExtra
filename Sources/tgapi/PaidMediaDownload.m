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
@property(nonatomic, strong) NSMutableDictionary<NSUUID *, MTRequest *> *pending;
@property(nonatomic) int64_t receivedBytes;
@property(nonatomic, strong) NSFileHandle *output;
@property(nonatomic, strong) NSURL *url;
@property(nonatomic) int64_t offset;
@property(nonatomic) BOOL done;
@property(nonatomic) NSTimeInterval nativeDeadline;
@property(nonatomic) double nativeProgress;
- (void)start;
@end

@implementation TGExtraPaidMediaDownload
- (void)finish:(NSError *)error {
    if (self.done) return;
    self.done = YES;
    for (MTRequest *request in self.pending.allValues) {
        request.completed = nil;
        [self.service removeRequestByInternalId:request.internalId];
    }
    [self.pending removeAllObjects];
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

- (void)failWithReason:(NSString *)reason {
    [self finish:[NSError errorWithDomain:@"TGExtra.PaidMedia" code:1
        userInfo:@{NSLocalizedDescriptionKey: reason}]];
}

- (void)readChunk {
    if (self.done) return;
    if (!self.pending) self.pending = [NSMutableDictionary new];
    // Unknown sizes need a single EOF probe; known sizes use a bounded window.
    NSUInteger window = self.media.size > 0 ? 4 : 1;
    while (!self.done && self.pending.count < window && (self.media.size == 0 || self.offset < self.media.size)) {
        int64_t offset = self.offset;
        NSData *payload = [self.media downloadRequestAtOffset:offset];
        if (!payload) { [self failWithReason:@"Invalid file request"]; return; }
        MTRequest *request = [NSClassFromString(@"MTRequest") new];
        if (!request) { [self failWithReason:@"MTRequest unavailable"]; return; }
        [request setPayload:payload metadata:nil shortMetadata:@"TGExtra.paidMedia"
            responseParser:^id(NSData *bytes) { return bytes; }];
        request.needsTimeoutTimer = YES;
        request.shouldContinueExecutionWithErrorContext = ^bool(id context) { return false; };
        NSUUID *token = NSUUID.UUID;
        self.pending[token] = request;
        self.offset += self.media.size > 0 ? MIN((int64_t)524288, self.media.size - offset) : 524288;
        request.completed = ^(id result, MTRequestResponseInfo *info, MTRpcError *error) {
            dispatch_async(mediaQueue(), ^{
                MTRequest *request = self.pending[token];
                if (self.done || !request) return;
                [self.pending removeObjectForKey:token];
                request.completed = nil;
                if (error) {
                    [self finish:[NSError errorWithDomain:@"TGExtra.PaidMedia.RPC" code:error.errorCode
                        userInfo:@{NSLocalizedDescriptionKey: error.errorDescription ?: @"File request failed"}]];
                    return;
                }
                NSData *bytes = [result isKindOfClass:NSData.class] ? [TGExtraForwardCopyPlan fileBytesFromResponse:result] : nil;
                int64_t remaining = self.media.size > 0 ? self.media.size - offset : INT64_MAX;
                if (!bytes || bytes.length > 524288 || (int64_t)bytes.length > remaining ||
                    (self.media.size > 0 && bytes.length != MIN((int64_t)524288, remaining))) {
                    [self failWithReason:@"Incomplete or invalid file response"]; return;
                }
                @try { [self.output seekToFileOffset:offset]; [self.output writeData:bytes]; }
                @catch (NSException *exception) { [self failWithReason:exception.reason ?: @"File write failed"]; return; }
                self.receivedBytes += bytes.length;
                BOOL complete = self.media.size > 0 ? self.receivedBytes == self.media.size : bytes.length < 524288;
                if (complete) {
                    if (self.receivedBytes == 0) [self failWithReason:@"Empty file response"];
                    else [self finish:nil];
                } else { [self readChunk]; }
            });
        };
        [self.service addRequest:request];
        __weak TGExtraPaidMediaDownload *weakSelf = self;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 120 * NSEC_PER_SEC), mediaQueue(), ^{
            TGExtraPaidMediaDownload *op = weakSelf;
            if (op && !op.done && op.pending[token]) [op failWithReason:@"File request timed out"];
        });
    }
}

- (BOOL)copyCompleteCache {
    if (self.media.cachePath) {
        NSDictionary *attributes = [NSFileManager.defaultManager attributesOfItemAtPath:self.media.cachePath error:NULL];
        int64_t size = [attributes[NSFileSize] longLongValue];
        if (size > 0 && (self.media.size == 0 || self.media.size == size)) {
            NSError *error = nil;
            [NSFileManager.defaultManager copyItemAtPath:self.media.cachePath toPath:self.url.path error:&error];
            [self finish:error];
            return YES;
        }
    }
    return NO;
}

- (void)waitForNativeDownload {
    if (self.done || [self copyCompleteCache]) return;
    if (NSProcessInfo.processInfo.systemUptime > self.nativeDeadline) {
        [self failWithReason:@"Native video download made no progress for 120 seconds"];
        return;
    }
    dispatch_async(dispatch_get_main_queue(), ^{
        NSNumber *progress = self.media.nativeDownloadProgress;
        dispatch_async(mediaQueue(), ^{
            if (progress && progress.doubleValue > self.nativeProgress) {
                self.nativeProgress = progress.doubleValue;
                self.nativeDeadline = NSProcessInfo.processInfo.systemUptime + 120;
            }
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC / 2), mediaQueue(), ^{
                [self waitForNativeDownload];
            });
        });
    });
}

- (void)startNetwork {
    if (self.media.nativeOnly) {
        [self failWithReason:@"Secret media must finish downloading in Telegram before it can be saved"];
        return;
    }
    SEL initializer = @selector(initWithContext:datacenterId:usageCalculationInfo:requiredAuthToken:authTokenMasterDatacenterId:);
    Class networkClass = NSClassFromString(@"MTProto"), serviceClass = NSClassFromString(@"MTRequestMessageService");
    if (![networkClass instancesRespondToSelector:initializer] ||
        ![serviceClass instancesRespondToSelector:@selector(initWithContext:)]) { [self failWithReason:@"Media transport unavailable"]; return; }
    BOOL otherDC = self.media.datacenterId != self.media.masterDatacenterId;
    NSNumber *token = otherDC ? @(self.media.datacenterId) : nil;
    self.network = [(TGExtraMediaConnection *)[networkClass alloc] initWithContext:self.media.context
        datacenterId:self.media.datacenterId usageCalculationInfo:nil requiredAuthToken:token
        authTokenMasterDatacenterId:otherDC ? self.media.masterDatacenterId : 0];
    self.service = (id)[(TGExtraMediaConnection *)[serviceClass alloc] initWithContext:self.media.context];
    if (!self.network || !self.service) { [self failWithReason:@"Media session unavailable"]; return; }
    [self.network setUseTempAuthKeys:[(TGExtraMediaConnection *)self.media.context useTempAuthKeys]];
    [self.network setMedia:true];
    self.service.delegate = self;
    if (![NSFileManager.defaultManager createFileAtPath:self.url.path contents:nil attributes:nil] ||
        !(self.output = [NSFileHandle fileHandleForWritingAtPath:self.url.path])) { [self failWithReason:@"Cannot create temporary file"]; return; }
    [self.network addMessageService:self.service];
    [self.network resume];
    [self readChunk];
}

- (void)start {
    self.url = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:
        [NSString stringWithFormat:@"TGExtraPaid-%@.%@", NSUUID.UUID.UUIDString, self.media.video ? @"mp4" : @"jpg"]]];
    if ([self copyCompleteCache]) return;
    if ((self.media.video || self.media.nativeOnly) && self.media.cachePath) {
        dispatch_async(dispatch_get_main_queue(), ^{
            BOOL native = [self.media beginNativeDownload];
            dispatch_async(mediaQueue(), ^{
                if (native) {
                    self.nativeProgress = -1;
                    self.nativeDeadline = NSProcessInfo.processInfo.systemUptime + 120;
                    [self waitForNativeDownload];
                } else { [self startNetwork]; }
            });
        });
    } else { [self startNetwork]; }
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
