#import <Foundation/Foundation.h>
#import "Logger/Logger.h"
#import "Constants.h"
#import "../tgapiC/include/Tweak.h"

@interface TLParser : NSObject
+ (BOOL)nativeTLAvailable;
+ (NSData *)handleResponse:(NSData *)data functionID:(NSNumber *)ios account:(NSString *)account requestPayload:(NSData *)payload;
+ (void)addDeletedId:(int32_t)msgId peer:(int64_t)peer account:(NSString *)account messageNamespace:(int32_t)messageNamespace;
+ (void)loadPersistedIds;
+ (BOOL)clearMessageData;
+ (NSNumber *)getMessageId:(id)item;
+ (NSNumber *)getMessageIdFromNode:(id)node;
+ (BOOL)isDeleted:(NSNumber *)msgId peer:(NSNumber *)peer account:(NSString *)account messageNamespace:(NSNumber *)messageNamespace;
+ (NSData *)stripAntiSelfDestruct:(NSData *)data account:(NSString *)account;
+ (void)registerVoiceUploadWithFileName:(NSString *)fileName
                               duration:(NSInteger)duration
                               waveform:(NSData *)waveform;
+ (BOOL)isMessageSelfDestructing:(NSNumber *)msgId peer:(NSNumber *)peer account:(NSString *)account messageNamespace:(NSNumber *)messageNamespace;
+ (NSData *)fakeResponseForPayload:(NSData *)payload;
+ (NSData *)rewriteRequestPayload:(NSData *)payload;
+ (BOOL)isForwardRequest:(NSData *)payload;
+ (NSData *)privacyReplacementRequest;
+ (NSString *)compatibilityReport;
+ (NSData *)rewriteVoiceUpload:(NSData *)data;
+ (NSData *)rewriteAppConfigRequest:(NSData *)data;
+ (NSDictionary<NSString *, NSData *> *)readMessageContentsPolicy:(NSData *)payload account:(NSString *)account;
+ (NSArray<NSString *> *)editHistoryForId:(NSNumber *)msgId peer:(NSNumber *)peer account:(NSString *)account messageNamespace:(NSNumber *)messageNamespace;
+ (NSArray<NSDictionary *> *)editRevisionDetailsForId:(NSNumber *)msgId peer:(NSNumber *)peer account:(NSString *)account messageNamespace:(NSNumber *)messageNamespace;
+ (NSNumber *)getMessagePeerKeyFromNode:(id)node;
+ (NSString *)getHistoryAccountFromNode:(id)node;
+ (NSNumber *)getMessageNamespaceFromNode:(id)node;
+ (NSDictionary<NSString *, id> *)messageStateFromNode:(id)node observe:(BOOL)observe;
+ (BOOL)hasAdMessageFromNode:(id)node;
@end

@interface MTRpcError : NSObject
@property (nonatomic, readonly) int32_t errorCode;
@property (nonatomic, strong, readonly) NSString *errorDescription;
- (id)initWithErrorCode:(int)code errorDescription:(id)desc;
@end

@interface MTRequestResponseInfo : NSObject
@property(nonatomic, readonly) int32_t networkType;
@property(nonatomic, readonly) double timestamp;
@property(nonatomic, readonly) double duration;
- (id)initWithNetworkType:(int)a  timestamp:(CGFloat)b  duration:(CGFloat)c;
@end

@interface MTRequest : NSObject
@property (nonatomic, strong, readonly) id internalId;
@property (nonatomic, strong) NSNumber *functionID;
@property (nonatomic, strong) NSData *fakeData;
@property (nonatomic, strong) NSData *payload;
@property (nonatomic, copy) void (^completed)(id boxedResponse, MTRequestResponseInfo *info, MTRpcError *error);
@property (nonatomic) bool needsTimeoutTimer;
@property (nonatomic, copy) bool (^shouldContinueExecutionWithErrorContext)(id context);
@property (nonatomic, strong, readonly) id (^responseParser)(NSData *);
@property (nonatomic, copy) id metadata;
@property (nonatomic, copy) id shortMetadata;
- (void)setPayload:(NSData *)payload metadata:(id)metadata shortMetadata:(id)shortMetadata responseParser:(id (^)(NSData *))responseParser;
@end

@interface MTRequestMessageService : NSObject
@property (nonatomic, weak) id delegate;
- (void)addRequest:(MTRequest *)request;
- (void)removeRequestByInternalId:(id)internalId;
- (void)removeRequestByInternalId:(id)internalId askForReconnectionOnDrop:(bool)askForReconnectionOnDrop;
@end

#ifdef __cplusplus
extern "C" {
#endif
BOOL TGExtraIsPreparingReadContentsRequest(MTRequest *request);
void TGExtraPrepareReadContentsRequest(MTRequest *request, NSString *account);
NSData *TGExtraFakeResponseForPayload(NSData *payload);
NSData *TGExtraRewriteRequestPayload(NSData *payload);
NSData *decompressGzip(const void *input, size_t inputLen);
#ifdef __cplusplus
}
#endif
