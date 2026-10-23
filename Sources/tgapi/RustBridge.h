#import <Foundation/Foundation.h>
#include <stdint.h>

// C ABI 5, TelegramMessenger/mtproto-engine da4b2170210aab0430c4ff18c032991f3030cf45.
// Names are scoped because the host also has an Objective-C MTRequest class.
typedef struct { const uint8_t *data; size_t length; } TGERustBytes;
typedef struct { const char *data; size_t length; } TGERustString;
typedef struct {
    uint64_t id;
    TGERustBytes body;
    uint32_t flags, expectedResponseSize;
    uint64_t invokeAfter;
} TGERustRequest;
typedef struct {
    uint32_t kind;
    uint64_t requestId;
    int32_t code;
    uint32_t flags;
    TGERustString text, text2;
    void *payload;
    double value1, value2;
    int64_t integer1, integer2;
    const void *salts;
    size_t saltCount;
} TGERustEvent;
typedef void (*TGERustEventCallback)(void *, uint64_t, const TGERustEvent *);
typedef void (*TGERustLogCallback)(void *, int32_t, TGERustString);
typedef void *(*TGERustCreate)(uint32_t, void *, void *, void *);
typedef const uint8_t *(*TGERustBufferData)(const void *);
typedef size_t (*TGERustBufferLength)(const void *);

// Offline arm64 call-site thunks pass the unmodified C function as their final
// argument. All pointer arguments/returns stay raw to preserve the host's ARC ABI.
@interface TGExtraRustBridge : NSObject
+ (void *)engineCreate:(uint32_t)threads context:(void *)context event:(void *)event log:(void *)log original:(void *)original;
+ (uint64_t)sessionCreate:(void *)engine setup:(const void *)setup original:(void *)original;
+ (void)sessionDestroy:(void *)engine session:(uint64_t)session original:(void *)original;
+ (void)send:(void *)engine session:(uint64_t)session request:(const TGERustRequest *)request original:(void *)original;
+ (void)cancel:(void *)engine session:(uint64_t)session request:(uint64_t)request original:(void *)original;
+ (const uint8_t *)bufferData:(const void *)buffer original:(void *)original;
+ (size_t)bufferLength:(const void *)buffer original:(void *)original;
+ (void)bufferFree:(void *)buffer original:(void *)original;
+ (void *)usageManager:(void *)receiver selector:(void *)selector info:(void *)info original:(void *)original;
+ (void *)authInfo:(void *)receiver selector:(void *)selector datacenter:(NSInteger)datacenter authSelector:(NSInteger)authSelector original:(void *)original;
#ifdef TGEXTRA_TESTING
+ (void)setBufferData:(TGERustBufferData)data length:(TGERustBufferLength)length;
+ (void)setCopyRequestID:(void *)next send:(void *)send cancel:(void *)cancel free:(void *)free;
#endif
@end
