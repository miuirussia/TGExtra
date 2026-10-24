#import "Headers.h"
#import "GhostExceptions.h"
#import <objc/runtime.h>

NSData *boolTrue(void);
static void handleContentReadReceipt(MTRequest *request, NSData *payload, NSString *key);

// Both transports use the same request policy. The carrier only needs fakeData;
// it must not allocate a host MTRequest or invoke its payload hooks recursively.
@interface TGExtraRequestDecision : NSObject
@property(nonatomic, strong) NSData *fakeData;
@end
@implementation TGExtraRequestDecision
@end

NSData *TGExtraFakeResponseForPayload(NSData *payload) {
    if (payload.length < 4) return nil;
    int32_t function = 0;
    [payload getBytes:&function length:4];
    MTRequest *decision = (MTRequest *)(id)[TGExtraRequestDecision new];
    switch (function) {
        case kAccountUpdateOnlineStatus: handleOnlineStatus(decision, payload); break;
        case kMessagesSetTypingAction: handleSetTyping(decision, payload); break;
        case kMessagesReadHistory: handleMessageReadReceipt(decision, payload); break;
        case kMessagesReadMentions: handleContentReadReceipt(decision, payload, kDisableMentionReadReceipt); break;
        case kMessagesReadReactions: handleContentReadReceipt(decision, payload, kDisableReactionReadReceipt); break;
        case kStoriesReadStories: handleStoriesReadReceipt(decision, payload); break;
        case kGetSponsoredMessages: handleGetSponsoredMessages(decision, payload); break;
        case -871347913: handleChannelsReadReceipt(decision, payload); break;
        case kSendScreenshotNotification: handleSendScreenshotNotification(decision, payload); break;
    }
    return decision.fakeData;
}

NSData *TGExtraRewriteRequestPayload(NSData *payload) {
    if (payload.length < 4) return payload;
    int32_t function = 0;
    [payload getBytes:&function length:4];
    if (function == kGetAppConfig) return [TLParser rewriteAppConfigRequest:payload] ?: payload;
    if (function == kMessagesSendMedia || function == kMessagesSendMultiMedia || function == kMessagesUploadMedia)
        return [TLParser rewriteVoiceUpload:payload] ?: payload;
    return payload;
}

NSData *boolTrue() {
    uint8_t bytes[] = {0xB5, 0x75, 0x72, 0x99}; // boolTrue#997275b5
    return [NSData dataWithBytes:bytes length:sizeof(bytes)];
}

NSData *boolFalse() {
    uint8_t bytes[] = {0x37, 0x97, 0x79, 0xBC}; // boolFalse#bc799737
    return [NSData dataWithBytes:bytes length:sizeof(bytes)];
}

// Handlers
void handleOnlineStatus(MTRequest *request, NSData *payload) {
	NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
	if (![defaults boolForKey:kGhostModeEnabled]) {
		tgextraDiag("updateStatus IGNORED — Ghost Mode is off");
		return;
	}

	if (payload.length < 4) return;

	NSData *isOfflineData = [payload subdataWithRange:NSMakeRange(payload.length - 4, 4)];
	uint32_t isOffline = 0;
	[isOfflineData getBytes:&isOffline length:4];

	BOOL wantsHidden = [defaults boolForKey:kDisableOnlineStatus];
	// 3162085175 == 0xBC799737 == boolFalse, i.e. offline:false — the client is
	// announcing that it just came online.
	BOOL goingOnline = (isOffline == 3162085175);

	tgextraDiag("updateStatus raw=0x%08X goingOnline=%d hideEnabled=%d len=%lu",
	         isOffline, goingOnline, wantsHidden, (unsigned long)payload.length);

	if (goingOnline && wantsHidden) {
		request.fakeData = boolTrue();
		tgextraDiag("updateStatus BLOCKED");
	}
}

// Walks an InputPeer, advancing *offset past it.
//
// outUserId, when non-NULL, receives the user_id for inputPeerUser and 0 for
// every other peer type. Ghost Exceptions only cover user peers (see
// GhostExceptions.h), so group/channel constructors deliberately report 0
// rather than their chat_id/channel_id.
static BOOL read_Input_Peer(NSData *data, int *offset, int64_t *outUserId, int depth) {
    if (outUserId) *outUserId = 0;
    if (depth >= 8 || *offset < 0 || (NSUInteger)*offset + 4 > data.length) return NO;
    int32_t constructor = 0;
    [data getBytes:&constructor range:NSMakeRange(*offset, 4)];
    *offset += 4;
    switch (constructor) {
        case 2134579434: case 2107670217: return YES; // empty / self
        case 900291769: *offset += 8; break;          // chat
        case -571955892:                             // user
            if ((NSUInteger)*offset + 16 > data.length) return NO;
            if (outUserId) [data getBytes:outUserId range:NSMakeRange(*offset, 8)];
            *offset += 16;
            break;
        case 666680316: *offset += 16; break;        // channel
        case -1468331492: case -1121318848: {        // user/channel from message
            if (!read_Input_Peer(data, offset, NULL, depth + 1)) return NO;
            if ((NSUInteger)*offset + 12 > data.length) return NO;
            if (constructor == -1468331492 && outUserId)
                [data getBytes:outUserId range:NSMakeRange(*offset + 4, 8)];
            *offset += 12;
            break;
        }
        default: return NO;
    }
    return (NSUInteger)*offset <= data.length;
}

// YES when this peer is on the Ghost Exceptions list and must therefore see
// your real activity.
static BOOL isGhostException(int64_t userId) {
	BOOL hit = userId != 0 && [TGExtraGhostExceptions containsPeerId:userId];
	if (hit) {
		tgextraDiag("ghost-exception HIT peer=%lld — letting real activity through", userId);
	}
	return hit;
}

void handleSetTyping(MTRequest *request, NSData *payload) {
    if (payload.length < 8) return;
	if (![[NSUserDefaults standardUserDefaults] boolForKey:kGhostModeEnabled]) return;

	int offset = 0;
	offset += 4; // Skip First 4 Bytes of constructor id;
	int32_t flags = 0;
	[payload getBytes:&flags range:NSMakeRange(offset, 4)];
	offset += 4;

	int64_t peerUserId = 0;
	if (!read_Input_Peer(payload, &offset, &peerUserId, 0)) return; // Read Peer

	tgextraDiag("setTyping peer=%lld", peerUserId);

	// Ghost Exception: this peer keeps seeing your real typing indicators.
	if (isGhostException(peerUserId)) return;

	if ((flags & (1 << 0)) != 0) {
		offset += 4; // Topic id
	}

	if (offset < 0 || (NSUInteger)offset + 4 > payload.length) return;
	int32_t actionID = 0;
	[payload getBytes:&actionID range:NSMakeRange(offset, 4)];

	NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
	bool shouldBlockAction = false;

	//customLog(@"Handle Set Typing action : %d actionData:%@", actionID, [payload description]);
	switch (actionID) {
		case kActionIDTyping:
		shouldBlockAction = [defaults boolForKey:kDisableTypingStatus];
		  break;
		case kActionIDRecordingVideo:
		  shouldBlockAction = [defaults boolForKey:kDisableRecordingVideoStatus];
		  break;
		case kActionIDUploadingVideo:
		  shouldBlockAction = [defaults boolForKey:kDisableUploadingVideoStatus];
		  break;
		case kActionIDRecordingAudio:
		  shouldBlockAction = [defaults boolForKey:kDisableRecordingVoiceStatus];
		  break;
		case kActionIDUploadingVoice:
		  shouldBlockAction = [defaults boolForKey:kDisableUploadingVoiceStatus];
		  break;
		case kActionIDUploadingPhoto:
		  shouldBlockAction = [defaults boolForKey:kDisableUploadingPhotoStatus];
		  break;
		case kActionIDUploadingFile:
		  shouldBlockAction = [defaults boolForKey:kDisableUploadingFileStatus];
		  break;
		case kActionIDChoosingLocation:
		  shouldBlockAction = [defaults boolForKey:kDisableChoosingLocationStatus];
		  break;
		case kActionIDChoosingContact:
		  shouldBlockAction = [defaults boolForKey:kDisableChoosingContactStatus];
		  break;
		case kActionIDPlayingGame:
		  shouldBlockAction = [defaults boolForKey:kDisablePlayingGameStatus];
		  break;
		case kActionIDRecordingRoundVideo:
		  shouldBlockAction = [defaults boolForKey:kDisableRecordingRoundVideoStatus];
		  break;
		case kActionIDUploadingRoundVideo:
		  shouldBlockAction = [defaults boolForKey:kDisableUploadingRoundVideoStatus];
		  break;
		case kActionIDSpeakingInGroupCall:
		  shouldBlockAction = [defaults boolForKey:kDisableSpeakingInGroupCallStatus];
		  break;
		case kActionIDReserverHistoryImport:
		  shouldBlockAction = [defaults boolForKey:@"reserverHistroyImport"];
		  break;
		case kActionIDChoosingSticker:
		  shouldBlockAction = [defaults boolForKey:kDisableChoosingStickerStatus];
		  break;
		case kActionIDEmojiInteraction:
		  shouldBlockAction = [defaults boolForKey:kDisableEmojiInteractionStatus];
		  break;
		case kActionIDEmojiAcknowledgement:
		  shouldBlockAction = [defaults boolForKey:kDisableEmojiAcknowledgementStatus];
		  break;
	}

	if (shouldBlockAction) {
		request.fakeData = boolTrue();
	}
}

void handleMessageReadReceipt(MTRequest *request, NSData *payload) {
	if (![[NSUserDefaults standardUserDefaults] boolForKey:kGhostModeEnabled]) return;

	// messages.readHistory#0e306d3a peer:InputPeer max_id:int
	// Ghost Exception: this peer keeps getting your real read receipts.
	int offset = 4; // skip constructor id
	int64_t peerUserId = 0;
	if (!read_Input_Peer(payload, &offset, &peerUserId, 0)) return;
	tgextraDiag("readHistory peer=%lld", peerUserId);
	if (isGhostException(peerUserId)) return;

	if ([[NSUserDefaults standardUserDefaults] boolForKey:kDisableMessageReadReceipt]) {

		 uint8_t header[] = {0x85, 0x91, 0xD1, 0x84}; // messages.affectedMessages#84d19185
		 int32_t pts = 0;
		 int32_t pts_count = 0;

		 NSMutableData *data = [NSMutableData data];
		 [data appendBytes:&header length:sizeof(header)];
		 [data appendBytes:&pts length:sizeof(pts)];
		 [data appendBytes:&pts_count length:sizeof(pts_count)];

		request.fakeData = data;
	}
}

static void handleContentReadReceipt(MTRequest *request, NSData *payload, NSString *key) {
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    if (![defaults boolForKey:kGhostModeEnabled] || ![defaults boolForKey:key] || payload.length < 8) return;
    int32_t function = 0, flags = 0;
    [payload getBytes:&function length:4];
    [payload getBytes:&flags range:NSMakeRange(4, 4)];
    int offset = 8;
    int64_t peerUserId = 0;
    if (!read_Input_Peer(payload, &offset, &peerUserId, 0) || isGhostException(peerUserId)) return;
    int32_t supportedFlags = function == kMessagesReadMentions ? 1 : 3;
    if (flags & ~supportedFlags) return;
    if (flags & 1) offset += 4;
    if ((NSUInteger)offset > payload.length) return;
    if ((flags & 2) && !read_Input_Peer(payload, &offset, NULL, 0)) return;
    if ((NSUInteger)offset != payload.length) return;
    int32_t response[] = {(int32_t)0xb45c69d1, 0, 0, 0}; // messages.affectedHistory
    request.fakeData = [NSData dataWithBytes:response length:sizeof(response)];
}

void handleStoriesReadReceipt(MTRequest *request, NSData *payload) {
    int offset = 4;
    int64_t peerUserId = 0;
    if (!read_Input_Peer(payload, &offset, &peerUserId, 0) || isGhostException(peerUserId)) return;
	if (![[NSUserDefaults standardUserDefaults] boolForKey:kGhostModeEnabled]) return;
	if ([[NSUserDefaults standardUserDefaults] boolForKey:kDisableStoriesReadReceipt]) {

		uint8_t vectorID[] = {0x15, 0xC4, 0xB5, 0x1C}; // vector#1cb5c415
		int32_t count = 0;

		NSMutableData *data = [NSMutableData data];
		[data appendBytes:&vectorID length:sizeof(vectorID)];
		[data appendBytes:&count length:sizeof(count)];

		request.fakeData = data;
	}
}

void handleGetSponsoredMessages(MTRequest *request, NSData *payload) {
	if ([[NSUserDefaults standardUserDefaults] boolForKey:kDisableAllAds]) {

		uint8_t header[] = {0x0F, 0X49, 0X39, 0X18}; // messages.sponsoredMessagesEmpty#1839490f
		request.fakeData = [NSData dataWithBytes:header length:sizeof(header)];
	}
}

void handleChannelsReadReceipt(MTRequest *request, NSData *payload) {
	if (![[NSUserDefaults standardUserDefaults] boolForKey:kGhostModeEnabled]) return;
	if ([[NSUserDefaults standardUserDefaults] boolForKey:kDisableMessageReadReceipt]) {
		request.fakeData = boolTrue();
	}
}

void handleSendScreenshotNotification(MTRequest *request, NSData *payload) {
	if ([[NSUserDefaults standardUserDefaults] boolForKey:kDisableScreenshotNotification]) {
		request.fakeData = [TLParser fakeUpdatesResponse];
	}
}

static char preparingReadContentsKey;

BOOL TGExtraIsPreparingReadContentsRequest(MTRequest *request) {
    return [objc_getAssociatedObject(request, &preparingReadContentsKey) boolValue];
}

// Run after the service is attached: setPayload alone has no account identity.
void TGExtraPrepareReadContentsRequest(MTRequest *request, NSString *account) {
    if (request.payload.length < 4) return;
    NSDictionary *policy = [TLParser readMessageContentsPolicy:request.payload account:account];
    if (!policy) return;
    request.fakeData = policy[@"response"];
    NSData *payload = policy[@"payload"];
    if (!payload) return;
    objc_setAssociatedObject(request, &preparingReadContentsKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    @try {
        [request setPayload:payload metadata:request.metadata shortMetadata:request.shortMetadata responseParser:request.responseParser];
    } @finally {
        objc_setAssociatedObject(request, &preparingReadContentsKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
}
