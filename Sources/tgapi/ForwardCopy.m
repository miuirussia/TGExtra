#import "ForwardCopy.h"
#import <CommonCrypto/CommonDigest.h>
#import <objc/runtime.h>

// Only Objective-C MtProtoKit entry points are used here. The account's
// existing MTContext supplies authorization, proxy settings and DC discovery.
@interface TGExtraCopyConnection : NSObject
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

static const void *internalCopyKey = &internalCopyKey;
static const void *wrappedCopyKey = &wrappedCopyKey;
static const NSUInteger copyChunkSize = 512 * 1024;

BOOL TGExtraIsInternalCopyRequest(MTRequest *request) {
    return [objc_getAssociatedObject(request, internalCopyKey) boolValue];
}

static dispatch_queue_t copyQueue(void) {
    static dispatch_queue_t queue;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ queue = dispatch_queue_create("TGExtra.ForwardCopy", DISPATCH_QUEUE_SERIAL); });
    return queue;
}

static NSMapTable *copyOperations(void) {
    static NSMapTable *operations;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ operations = [NSMapTable weakToStrongObjectsMapTable]; });
    return operations;
}

static NSMutableDictionary *runningCopyKeys(void) {
    static NSMutableDictionary *keys;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ keys = [NSMutableDictionary new]; });
    return keys;
}

static id copyValue(id object, NSString *key) {
    @try { return [object valueForKey:key]; }
    @catch (NSException *exception) { return nil; }
}

static MTRpcError *copyError(NSString *reason) {
    return [[NSClassFromString(@"MTRpcError") alloc] initWithErrorCode:400 errorDescription:reason];
}

#if TGEXTRA_TESTING
static NSURL *copyTestDirectory;
void TGExtraSetCopyTestDirectory(NSURL *directory) {
    dispatch_sync(copyQueue(), ^{ copyTestDirectory = directory; });
}
void TGExtraDrainCopyTestQueue(void) { dispatch_sync(copyQueue(), ^{}); }
#endif

static NSURL *copyJournalDirectory(void) {
#if TGEXTRA_TESTING
    return copyTestDirectory;
#else
    NSURL *root = [NSFileManager.defaultManager URLsForDirectory:NSApplicationSupportDirectory inDomains:NSUserDomainMask].firstObject;
    return [root URLByAppendingPathComponent:@"TGExtra/ForwardCopies" isDirectory:YES];
#endif
}

@interface TGExtraForwardOperation : NSObject
@property(nonatomic, strong) MTRequest *original;
@property(nonatomic, weak) MTRequestMessageService *service;
@property(nonatomic, strong) TGExtraForwardCopyPlan *plan;
@property(nonatomic, copy) void (^completion)(id, MTRequestResponseInfo *, MTRpcError *);
@property(nonatomic, strong) MTRequestResponseInfo *info;
@property(nonatomic, strong) id master;
@property(nonatomic, strong) NSMutableDictionary<NSNumber *, id> *workers;
@property(nonatomic, strong) NSMutableDictionary<NSNumber *, MTRequestMessageService *> *workerServices;
@property(nonatomic, strong) MTRequest *pending;
@property(nonatomic, strong) MTRequestMessageService *pendingService;
@property(nonatomic, strong) NSObject *pendingToken;
@property(nonatomic, strong) NSURL *journalURL;
@property(nonatomic, strong) NSMutableDictionary *journal;
@property(nonatomic, strong) NSString *operationKey;
@property(nonatomic, strong) NSURL *temporaryDirectory;
@property(nonatomic, strong) NSFileHandle *file;
@property(nonatomic, strong) NSURL *fileURL;
@property(nonatomic) NSUInteger download;
@property(nonatomic) int64_t offset;
@property(nonatomic) int64_t fileId;
@property(nonatomic) int32_t part;
@property(nonatomic) int32_t parts;
@property(nonatomic) BOOL refreshed;
@property(nonatomic) BOOL started;
@property(nonatomic) BOOL done;
@property(nonatomic) CC_MD5_CTX md5;
@property(nonatomic, copy) NSString *checksum;
- (void)receiveOriginal:(id)result info:(MTRequestResponseInfo *)info error:(MTRpcError *)error;
- (void)cancel;
@end

@implementation TGExtraForwardOperation

- (void)closeFile {
    @try { [self.file closeFile]; } @catch (NSException *exception) {}
    self.file = nil;
}

- (void)cleanup {
    if (self.pending) [self.pendingService removeRequestByInternalId:self.pending.internalId];
    self.pending = nil; self.pendingService = nil; self.pendingToken = nil;
    [self closeFile];
    for (NSNumber *dc in self.workers) {
        TGExtraCopyConnection *network = self.workers[dc];
        [network removeMessageService:self.workerServices[dc]];
        [network stop];
    }
    [self.workers removeAllObjects]; [self.workerServices removeAllObjects];
    if (self.temporaryDirectory) [NSFileManager.defaultManager removeItemAtURL:self.temporaryDirectory error:nil];
    NSMapTable *operations = [copyOperations() objectForKey:self.service];
    [operations removeObjectForKey:self.original.internalId];
    if (self.operationKey && runningCopyKeys()[self.operationKey] == self) [runningCopyKeys() removeObjectForKey:self.operationKey];
}

- (void)complete:(id)result info:(MTRequestResponseInfo *)info error:(MTRpcError *)error {
    if (self.done) return;
    self.done = YES;
    [self cleanup];
    void (^completion)(id, MTRequestResponseInfo *, MTRpcError *) = self.completion;
    self.completion = nil;
    if (completion) completion(result, info, error);
    self.original = nil; self.master = nil;
}

- (void)fail:(NSString *)reason {
    [self complete:nil info:self.info error:copyError(reason)];
}

- (void)cancel {
    if (self.done) return;
    self.done = YES;
    [self cleanup];
    self.completion = nil; self.original = nil; self.master = nil;
}

- (void)rpc:(NSData *)payload service:(MTRequestMessageService *)service
 completion:(void (^)(NSData *, MTRpcError *))completion {
    if (self.done) return;
    if (!payload || !service || self.pending) { [self fail:@"TGEXTRA_COPY_NETWORK_UNAVAILABLE"]; return; }
    MTRequest *request = [NSClassFromString(@"MTRequest") new];
    objc_setAssociatedObject(request, internalCopyKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [request setPayload:payload metadata:nil shortMetadata:@"TGExtra.copy" responseParser:^id(NSData *bytes) { return bytes; }];
    request.needsTimeoutTimer = YES;
    request.shouldContinueExecutionWithErrorContext = ^bool(id context) { return false; };
    NSObject *token = [NSObject new];
    self.pendingToken = token; self.pending = request; self.pendingService = service;
    __weak TGExtraForwardOperation *weakSelf = self;
    request.completed = ^(id result, MTRequestResponseInfo *info, MTRpcError *error) {
        dispatch_async(copyQueue(), ^{
            TGExtraForwardOperation *op = weakSelf;
            if (!op || op.done || op.pendingToken != token) return;
            op.pending = nil; op.pendingService = nil; op.pendingToken = nil;
            if (info) op.info = info;
            completion([result isKindOfClass:NSData.class] ? result : nil, error);
        });
    };
    [service addRequest:request];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 120 * NSEC_PER_SEC), copyQueue(), ^{
        TGExtraForwardOperation *op = weakSelf;
        if (op && !op.done && op.pendingToken == token) [op fail:@"TGEXTRA_COPY_TIMEOUT"];
    });
}

- (MTRequestMessageService *)downloadService:(NSNumber *)dc {
    if (self.workerServices[dc]) return self.workerServices[dc];
    id context = copyValue(self.master, @"context");
    NSInteger masterId = [copyValue(self.master, @"datacenterId") integerValue];
    if (!context || masterId <= 0) return nil;
    SEL initializer = @selector(initWithContext:datacenterId:usageCalculationInfo:requiredAuthToken:authTokenMasterDatacenterId:);
    Class networkClass = NSClassFromString(@"MTProto"), serviceClass = NSClassFromString(@"MTRequestMessageService");
    if (![networkClass instancesRespondToSelector:initializer] ||
        ![serviceClass instancesRespondToSelector:@selector(initWithContext:)]) return nil;
    BOOL otherDC = dc.integerValue != masterId;
    TGExtraCopyConnection *network = [(TGExtraCopyConnection *)[networkClass alloc] initWithContext:context datacenterId:dc.integerValue
        usageCalculationInfo:copyValue(self.master, @"usageCalculationInfo")
        requiredAuthToken:otherDC ? dc : nil authTokenMasterDatacenterId:otherDC ? masterId : 0];
    MTRequestMessageService *service = (MTRequestMessageService *)[(TGExtraCopyConnection *)[serviceClass alloc] initWithContext:context];
    if (!network || !service) return nil;
    [network setUseTempAuthKeys:[(TGExtraCopyConnection *)context useTempAuthKeys]];
    [network setMedia:true];
    service.delegate = self;
    [network addMessageService:service];
    [network resume];
    self.workers[dc] = network; self.workerServices[dc] = service;
    return service;
}

- (void)requestMessageServiceAuthorizationRequired:(MTRequestMessageService *)service {
    dispatch_async(copyQueue(), ^{
        if (self.done) return;
        for (NSNumber *dc in self.workerServices) {
            if (self.workerServices[dc] != service) continue;
            NSInteger master = [copyValue(self.master, @"datacenterId") integerValue];
            if (dc.integerValue == master) return;
            TGExtraCopyConnection *context = copyValue(self.master, @"context");
            [context updateAuthTokenForDatacenterWithId:dc.integerValue authToken:nil];
            [context authTokenForDatacenterWithIdRequired:dc.integerValue authToken:dc masterDatacenterId:master];
            return;
        }
    });
}

- (BOOL)saveJournal {
    self.journal[@"updated"] = NSDate.date;
    NSError *error = nil;
    NSData *bytes = [NSPropertyListSerialization dataWithPropertyList:self.journal format:NSPropertyListBinaryFormat_v1_0 options:0 error:&error];
    return bytes && [bytes writeToURL:self.journalURL options:NSDataWritingAtomic error:&error];
}

- (BOOL)openJournalForAccount:(NSString *)account {
    NSURL *directory = copyJournalDirectory();
    if (!directory || ![NSFileManager.defaultManager createDirectoryAtURL:directory withIntermediateDirectories:YES attributes:nil error:nil]) return NO;
    [directory setResourceValue:@YES forKey:NSURLIsExcludedFromBackupKey error:nil];
    self.operationKey = [TGExtraForwardCopyPlan operationKeyForAccount:account payload:self.original.payload];
    if (runningCopyKeys()[self.operationKey] && runningCopyKeys()[self.operationKey] != self) return NO;
    self.journalURL = [directory URLByAppendingPathComponent:[self.operationKey stringByAppendingPathExtension:@"plist"]];
    NSDictionary *saved = [NSDictionary dictionaryWithContentsOfURL:self.journalURL];
    if (saved) {
        if (![saved[@"account"] isEqual:account] || ![saved[@"payload"] isEqual:self.original.payload] ||
            ![saved[@"requests"] isKindOfClass:NSArray.class] || ![saved[@"results"] isKindOfClass:NSDictionary.class] ||
            ![self.plan restoreRequests:saved[@"requests"]]) return NO;
        self.journal = saved.mutableCopy;
        self.journal[@"results"] = [saved[@"results"] mutableCopy];
    } else {
        // Completed journals are retained for a week so replays keep their real
        // results. Unfinished journals are never evicted to make room.
        NSArray *files = [NSFileManager.defaultManager contentsOfDirectoryAtURL:directory includingPropertiesForKeys:nil options:0 error:nil];
        NSUInteger retained = 0;
        for (NSURL *url in files) {
            NSDictionary *entry = [NSDictionary dictionaryWithContentsOfURL:url];
            NSDate *date = entry[@"updated"];
            if ([entry[@"complete"] boolValue] && [date isKindOfClass:NSDate.class] && -date.timeIntervalSinceNow > 7 * 86400) {
                [NSFileManager.defaultManager removeItemAtURL:url error:nil];
            } else { retained++; }
        }
        if (retained >= 128) return NO;
        self.journal = [@{@"account": account, @"payload": self.original.payload, @"results": [NSMutableDictionary new]} mutableCopy];
    }
    runningCopyKeys()[self.operationKey] = self;
    return YES;
}

- (void)receiveOriginal:(id)result info:(MTRequestResponseInfo *)info error:(MTRpcError *)error {
    if (self.done) return;
    if (self.started) return;
    self.info = info;
    if (!error || ![error.errorDescription isEqualToString:@"CHAT_FORWARDS_RESTRICTED"] ||
        (error.errorCode != 400 && error.errorCode != 406) ||
        ![NSUserDefaults.standardUserDefaults boolForKey:kDisableForwardRestriction]) {
        [self complete:result info:info error:error];
        return;
    }
    self.started = YES;
    NSString *account = TGExtraHistoryAccountForRequestService(self.service);
    self.master = copyValue(self.service, @"mtProto");
    if (!account || !self.master) { [self complete:result info:info error:error]; return; }
    self.workers = [NSMutableDictionary new]; self.workerServices = [NSMutableDictionary new];
    if (![self openJournalForAccount:account]) { [self fail:@"TGEXTRA_COPY_JOURNAL_UNAVAILABLE"]; return; }
    if (self.journal[@"requests"]) { [self sendBatch:0]; return; }
    [self rpc:self.plan.sourceRequest service:self.service completion:^(NSData *bytes, MTRpcError *rpcError) {
        if (rpcError) { [self complete:nil info:self.info error:rpcError]; return; }
        if (!bytes || ![self.plan prepareWithResponse:bytes]) { [self fail:self.plan.errorDescription]; return; }
        [self nextDownload];
    }];
}

- (void)nextDownload {
    [self closeFile];
    if (self.fileURL) [NSFileManager.defaultManager removeItemAtURL:self.fileURL error:nil];
    if (self.download >= self.plan.downloads.count) {
        if (![self.plan buildRequests]) { [self fail:self.plan.errorDescription]; return; }
        self.journal[@"requests"] = self.plan.requests;
        if (![self saveJournal]) { [self fail:@"TGEXTRA_COPY_JOURNAL_UNAVAILABLE"]; return; }
        [self sendBatch:0];
        return;
    }
    if (!self.temporaryDirectory) {
        NSURL *root = [[NSURL fileURLWithPath:NSTemporaryDirectory() isDirectory:YES] URLByAppendingPathComponent:@"TGExtraForwardCopies" isDirectory:YES];
        static dispatch_once_t once;
        dispatch_once(&once, ^{
            // This runs on copyQueue before any operation creates a file.
            // Remove only TGExtra's own files left by a terminated process.
            [NSFileManager.defaultManager removeItemAtURL:root error:nil];
        });
        self.temporaryDirectory = [root URLByAppendingPathComponent:NSUUID.UUID.UUIDString isDirectory:YES];
        if (![NSFileManager.defaultManager createDirectoryAtURL:self.temporaryDirectory withIntermediateDirectories:YES attributes:nil error:nil]) {
            [self fail:@"TGEXTRA_COPY_DISK_ERROR"]; return;
        }
    }
    self.fileURL = [self.temporaryDirectory URLByAppendingPathComponent:@"media"];
    if (![NSFileManager.defaultManager createFileAtPath:self.fileURL.path contents:nil attributes:nil]) { [self fail:@"TGEXTRA_COPY_DISK_ERROR"]; return; }
    self.file = [NSFileHandle fileHandleForWritingAtPath:self.fileURL.path];
    if (!self.file) { [self fail:@"TGEXTRA_COPY_DISK_ERROR"]; return; }
    self.offset = 0; self.refreshed = NO;
    CC_MD5_Init(&_md5);
    [self downloadPart];
}

- (void)downloadPart {
    NSDictionary *item = self.plan.downloads[self.download];
    NSInteger index = [item[@"index"] integerValue];
    int64_t size = [item[@"size"] longLongValue];
    [self rpc:[self.plan downloadRequestForIndex:index offset:self.offset] service:[self downloadService:item[@"dc"]]
        completion:^(NSData *response, MTRpcError *error) {
        if (error) {
            if (!self.refreshed && [error.errorDescription hasPrefix:@"FILE_REFERENCE_"]) {
                self.refreshed = YES;
                [self rpc:self.plan.sourceRequest service:self.service completion:^(NSData *fresh, MTRpcError *refreshError) {
                    if (refreshError) { [self complete:nil info:self.info error:refreshError]; return; }
                    if (!fresh || ![self.plan refreshDownloadWithResponse:fresh index:index]) { [self fail:@"TGEXTRA_COPY_SOURCE_CHANGED"]; return; }
                    [self downloadPart];
                }];
            } else { [self complete:nil info:self.info error:error]; }
            return;
        }
        NSData *bytes = response ? [TGExtraForwardCopyPlan fileBytesFromResponse:response] : nil;
        if (!bytes || bytes.length != MIN((int64_t)copyChunkSize, size - self.offset)) { [self fail:@"TGEXTRA_COPY_FILE_INVALID"]; return; }
        @try { [self.file writeData:bytes]; }
        @catch (NSException *exception) { [self fail:@"TGEXTRA_COPY_DISK_ERROR"]; return; }
        CC_MD5_Update(&self->_md5, bytes.bytes, (CC_LONG)bytes.length);
        self.offset += bytes.length;
        if (self.offset < size) { [self downloadPart]; return; }
        unsigned char digest[CC_MD5_DIGEST_LENGTH];
        CC_MD5_Final(digest, &self->_md5);
        NSMutableString *checksum = [NSMutableString new];
        for (NSUInteger i = 0; i < CC_MD5_DIGEST_LENGTH; i++) [checksum appendFormat:@"%02x", digest[i]];
        self.checksum = checksum;
        [self closeFile];
        self.file = [NSFileHandle fileHandleForReadingAtPath:self.fileURL.path];
        if (!self.file) { [self fail:@"TGEXTRA_COPY_DISK_ERROR"]; return; }
        arc4random_buf(&self->_fileId, sizeof(self->_fileId));
        self.parts = (int32_t)((size + copyChunkSize - 1) / copyChunkSize); self.part = 0;
        [self uploadPart];
    }];
}

- (void)uploadPart {
    NSDictionary *item = self.plan.downloads[self.download];
    NSInteger index = [item[@"index"] integerValue];
    BOOL big = [item[@"size"] longLongValue] > 10 * 1024 * 1024;
    if (self.part >= self.parts) {
        [self rpc:[self.plan mediaUploadRequestForIndex:index fileId:self.fileId parts:self.parts md5:self.checksum]
            service:self.service completion:^(NSData *response, MTRpcError *error) {
            if (error) { [self complete:nil info:self.info error:error]; return; }
            if (!response || ![self.plan registerMediaResponse:response index:index]) { [self fail:@"TGEXTRA_COPY_UPLOAD_INVALID"]; return; }
            self.download++;
            [self nextDownload];
        }];
        return;
    }
    NSData *part;
    @try { part = [self.file readDataOfLength:copyChunkSize]; }
    @catch (NSException *exception) { [self fail:@"TGEXTRA_COPY_DISK_ERROR"]; return; }
    [self rpc:[TGExtraForwardCopyPlan uploadRequestForFileId:self.fileId part:self.part total:self.parts bytes:part big:big]
        service:self.service completion:^(NSData *response, MTRpcError *error) {
        if (error) { [self complete:nil info:self.info error:error]; return; }
        if (!response || ![TGExtraForwardCopyPlan isUploadAcknowledged:response]) { [self fail:@"TGEXTRA_COPY_UPLOAD_INVALID"]; return; }
        self.part++;
        [self uploadPart];
    }];
}

- (void)normalizeBatch:(NSUInteger)batch response:(NSData *)response {
    NSData *confirmation = [self.plan confirmationRequestForResponse:response];
    void (^finish)(NSData *, MTRpcError *) = ^(NSData *messages, MTRpcError *error) {
        if (error) { [self complete:nil info:self.info error:error]; return; }
        NSData *normalized = [self.plan normalizeResponse:response confirmation:messages batch:batch];
        if (!normalized) { [self fail:@"TGEXTRA_COPY_RESPONSE_INVALID"]; return; }
        NSMutableDictionary *entry = [self.journal[@"results"][@(batch).stringValue] mutableCopy];
        entry[@"normalized"] = normalized;
        self.journal[@"results"][@(batch).stringValue] = entry;
        if (![self saveJournal]) { [self fail:@"TGEXTRA_COPY_JOURNAL_UNAVAILABLE"]; return; }
        [self sendBatch:batch + 1];
    };
    if (confirmation) [self rpc:confirmation service:self.service completion:finish];
    else finish(nil, nil);
}

- (void)sendBatch:(NSUInteger)batch {
    if (self.done) return;
    if (batch >= self.plan.requests.count) {
        NSMutableArray *responses = [NSMutableArray new];
        for (NSUInteger i = 0; i < self.plan.requests.count; i++) {
            NSData *bytes = self.journal[@"results"][@(i).stringValue][@"normalized"];
            if (![bytes isKindOfClass:NSData.class] || ![self.plan normalizeResponse:bytes confirmation:nil batch:i]) {
                [self fail:@"TGEXTRA_COPY_JOURNAL_INVALID"]; return;
            }
            [responses addObject:bytes];
        }
        NSData *merged = [TGExtraForwardCopyPlan mergeResponses:responses];
        id result = merged && self.original.responseParser ? self.original.responseParser(merged) : nil;
        if (!result) { [self fail:@"TGEXTRA_COPY_RESPONSE_INVALID"]; return; }
        self.journal[@"complete"] = @YES;
        if (![self saveJournal]) { [self fail:@"TGEXTRA_COPY_JOURNAL_UNAVAILABLE"]; return; }
        [self complete:result info:self.info error:nil];
        return;
    }
    NSDictionary *entry = self.journal[@"results"][@(batch).stringValue];
    if ([entry[@"normalized"] isKindOfClass:NSData.class]) { [self sendBatch:batch + 1]; return; }
    if ([entry[@"raw"] isKindOfClass:NSData.class]) { [self normalizeBatch:batch response:entry[@"raw"]]; return; }
    [self rpc:self.plan.requests[batch][@"payload"] service:self.service completion:^(NSData *response, MTRpcError *error) {
        if (error) { [self complete:nil info:self.info error:error]; return; }
        if (!response) { [self fail:@"TGEXTRA_COPY_RESPONSE_INVALID"]; return; }
        // Persist the ACK before fetching a compact reply's full message. A
        // failed confirmation fetch must never cause a second send on retry.
        self.journal[@"results"][@(batch).stringValue] = @{@"raw": response};
        if (![self saveJournal]) { [self fail:@"TGEXTRA_COPY_JOURNAL_UNAVAILABLE"]; return; }
        [self normalizeBatch:batch response:response];
    }];
}
@end

void TGExtraWrapForwardRequest(MTRequest *request, MTRequestMessageService *service) {
    if (TGExtraIsInternalCopyRequest(request) || objc_getAssociatedObject(request, wrappedCopyKey) ||
        !request.completed || !request.internalId ||
        ![NSUserDefaults.standardUserDefaults boolForKey:kDisableForwardRestriction]) return;
    TGExtraForwardCopyPlan *plan = [[TGExtraForwardCopyPlan alloc] initWithPayload:request.payload];
    if (!plan || !plan.sourceRequest) return;
    TGExtraForwardOperation *operation = [TGExtraForwardOperation new];
    operation.original = request; operation.service = service; operation.plan = plan;
    operation.completion = request.completed;
    __weak TGExtraForwardOperation *weakOperation = operation;
    request.completed = ^(id result, MTRequestResponseInfo *info, MTRpcError *error) {
        dispatch_async(copyQueue(), ^{ [weakOperation receiveOriginal:result info:info error:error]; });
    };
    objc_setAssociatedObject(request, wrappedCopyKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    dispatch_async(copyQueue(), ^{
        NSMapTable *operations = [copyOperations() objectForKey:service];
        if (!operations) {
            operations = [NSMapTable strongToStrongObjectsMapTable];
            [copyOperations() setObject:operations forKey:service];
        }
        [operations setObject:operation forKey:request.internalId];
    });
}

void TGExtraCancelForwardRequest(id internalId, MTRequestMessageService *service) {
    if (!internalId) return;
    dispatch_async(copyQueue(), ^{
        TGExtraForwardOperation *operation = [[copyOperations() objectForKey:service] objectForKey:internalId];
        [operation cancel];
    });
}
