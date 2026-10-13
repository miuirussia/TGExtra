#import <Foundation/Foundation.h>
#import "Logger/Logger.h"
#import "Constants.h"

@interface TLParser : NSObject
+ (NSData *)handleResponse:(NSData *)data functionID:(NSNumber *)ios;
+ (void)addDeletedId:(int32_t)msgId peer:(int64_t)peer;
+ (void)loadPersistedIds;
+ (NSNumber *)getMessageId:(id)item;
+ (NSNumber *)getCurrentUserId;
+ (NSDictionary<NSString *, NSString *> *)getPeerDisplayInfoFromNode:(id)node;
+ (NSDictionary<NSString *, NSString *> *)cachedPeerInfoForId:(NSNumber *)peerId;
+ (NSString *)debugPeerCandidates:(id)node;
+ (NSNumber *)getMessageIdFromNode:(id)node;
+ (NSString *)getDebugDumpFromNode:(id)node;
+ (BOOL)isDeleted:(NSNumber *)msgId peer:(NSNumber *)peer;
+ (NSData *)stripAntiSelfDestruct:(NSData *)data;
+ (void)registerVoiceUploadWithFileName:(NSString *)fileName
                               duration:(NSInteger)duration
                               waveform:(NSData *)waveform;
+ (BOOL)isMessageSelfDestructing:(NSNumber *)msgId peer:(NSNumber *)peer;
+ (NSData *)fakeUpdatesResponse;
+ (NSData *)rewriteVoiceUpload:(NSData *)data;
+ (NSArray<NSString *> *)editHistoryForId:(NSNumber *)msgId peer:(NSNumber *)peer;
+ (NSNumber *)getMessagePeerKeyFromNode:(id)node;
@end

@interface MTRpcError : NSObject
- (id)initWithErrorCode:(int)code errorDescription:(id)desc;
@end

@interface MTRequestResponseInfo : NSObject
- (id)initWithNetworkType:(int)a  timestamp:(CGFloat)b  duration:(CGFloat)c;
@end

@interface MTRequest : NSObject
@property (nonatomic, strong) NSNumber *functionID;
@property (nonatomic, strong) NSData *fakeData;
@property (nonatomic, strong) NSData *payload;
@property (nonatomic, copy) void (^completed)(id boxedResponse, MTRequestResponseInfo *info, MTRpcError *error);
@property (nonatomic, strong, readonly) id (^responseParser)(NSData *);
@property (nonatomic, copy) id metadata;
@property (nonatomic, copy) id shortMetadata;
- (void)setPayload:(NSData *)payload metadata:(id)metadata shortMetadata:(id)shortMetadata responseParser:(id (^)(NSData *))responseParser;
@end

@interface MTRequestMessageService : NSObject
- (void)addRequest:(MTRequest *)request;
@end

// Function Handlers
#ifdef __cplusplus
extern "C" {
#endif
void handleOnlineStatus(MTRequest *request, NSData *payload);
void handleSetTyping(MTRequest *request, NSData *payload);
void handleMessageReadReceipt(MTRequest *request, NSData *payload);
void handleStoriesReadReceipt(MTRequest *request, NSData *payload);
void handleGetSponsoredMessages(MTRequest *request, NSData *payload);
void handleChannelsReadReceipt(MTRequest *request, NSData *payload);
void handleSendScreenshotNotification(MTRequest *request, NSData *payload);
void handleReadMessageContents(MTRequest *request, NSData *payload);
NSData *decompressGzip(const void *input, size_t inputLen);
#ifdef __cplusplus
}
#endif
