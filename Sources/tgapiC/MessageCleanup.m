#import "include/Tweak.h"
#include <dlfcn.h>

// Use the exported Swift methods, preserving swiftself and Swift closure ABI.
// No Telegram network deletion requests are issued by this bridge.
typedef struct { void *buffer[3]; const void *metadata; const void *witness; } TGExtraDisposable;
typedef void * __attribute__((swiftcall)) (*TransactionFunction)(BOOL, BOOL, void *, void *, uintptr_t, uintptr_t, intptr_t, const void *, void * __attribute__((swift_context)));
typedef TGExtraDisposable __attribute__((swiftcall)) (*StartFunction)(void *, void *, void *, void *, void *, void *, void * __attribute__((swift_context)));
typedef void __attribute__((swiftcall)) (*DeleteFunction)(void *, void *, void *, void * __attribute__((swift_context)));
typedef void __attribute__((swiftcall)) (*DeleteRangeFunction)(uint32_t, int64_t, int32_t, int32_t, int32_t, void *, void *, void * __attribute__((swift_context)));
typedef void __attribute__((swiftcall)) (*VisitFunction)(uint32_t, int64_t, uint64_t, void *, void *, void * __attribute__((swift_context)));

static void *hostMethod(const char *name) { return dlsym(RTLD_DEFAULT, name); }

extern void TGExtraMessageCleanupBody(void *context, void *transaction);
extern void TGExtraMessageCleanupCompleted(void *context);
extern void TGExtraMessageCleanupReleaseDisposable(void *disposable);
extern void TGExtraSecretChatClearedMessage(void *context, void *message);

static bool __attribute__((swiftcall)) clearedMessage(void *message, void *context __attribute__((swift_context))) {
    TGExtraSecretChatClearedMessage(context, message);
    return true;
}

void TGExtraVisitLocalMessages(void *transaction, uint32_t peerNamespace, int64_t peer, void *context) {
    VisitFunction visit = hostMethod("$s7Postbox11TransactionC15withAllMessages6peerId9namespace_yAA04PeerG0V_s5Int32VSgSbAA7MessageCXEtF");
    // Optional<Int32>.none is the extra tag bit above its 32-bit payload.
    if (visit) visit(peerNamespace, peer, 1ULL << 32, clearedMessage, context, transaction);
}

// Postbox's generic result is indirect, but Transaction is a concrete class.
static void __attribute__((swiftcall)) cleanupBody(void *result __attribute__((swift_indirect_result)), void *transaction, void *context __attribute__((swift_context))) {
    TGExtraMessageCleanupBody(context, transaction);
}
static void __attribute__((swiftcall)) cleanupCompleted(void *context __attribute__((swift_context))) {
    TGExtraMessageCleanupCompleted(context);
}

BOOL TGExtraMessageCleanupAvailable(void) {
    return hostMethod("$s7PostboxAAC11transaction15userInteractive14ignoreDisabled_4file4line14SwiftSignalKit0J0CyxAH7NoErrorOGSb_SbxAA11TransactionCcSSSitlF") &&
        hostMethod("$s14SwiftSignalKit0B0C5start4next5error9completedAA10Disposable_pyxcSg_yq_cSgyycSgtF") &&
        hostMethod("$s7Postbox11TransactionC14deleteMessages_12forEachMediaySayAA9MessageIdVG_yAA0G0_pcSgtF") &&
        hostMethod("$s7Postbox11TransactionC27deleteMessagesWithGlobalIds_12forEachMediaySays5Int32VG_yAA0J0_pcSgtF") &&
        hostMethod("$s7Postbox11TransactionC21deleteMessagesInRange6peerId9namespace03minH003maxH012forEachMediayAA04PeerH0V_s5Int32VA2MyAA0N0_pcSgtF");
}

void TGExtraRunMessageCleanup(void *postbox, void *context, const void *voidMetadata) {
    TransactionFunction transaction = hostMethod("$s7PostboxAAC11transaction15userInteractive14ignoreDisabled_4file4line14SwiftSignalKit0J0CyxAH7NoErrorOGSb_SbxAA11TransactionCcSSSitlF");
    StartFunction start = hostMethod("$s14SwiftSignalKit0B0C5start4next5error9completedAA10Disposable_pyxcSg_yq_cSgyycSgtF");
    // An empty Swift String uses the small-string discriminator in its second word.
    void *signal = transaction(NO, NO, cleanupBody, context, 0, (uintptr_t)0xe000000000000000ULL, 0, voidMetadata, postbox);
    TGExtraDisposable disposable = start(NULL, NULL, NULL, NULL, cleanupCompleted, context, signal);
    TGExtraMessageCleanupReleaseDisposable(&disposable);
    void (*release)(void *) = hostMethod("swift_release");
    release(signal);
}

void TGExtraDeleteLocalMessages(void *transaction, void *ids, BOOL global) {
    DeleteFunction deleteMessages = hostMethod(global
        ? "$s7Postbox11TransactionC27deleteMessagesWithGlobalIds_12forEachMediaySays5Int32VG_yAA0J0_pcSgtF"
        : "$s7Postbox11TransactionC14deleteMessages_12forEachMediaySayAA9MessageIdVG_yAA0G0_pcSgtF");
    deleteMessages(ids, NULL, NULL, transaction);
}

void TGExtraDeleteLocalMessageRange(void *transaction, uint32_t peerNamespace, int64_t peer, int32_t messageNamespace, int32_t maxId) {
    DeleteRangeFunction deleteRange = hostMethod("$s7Postbox11TransactionC21deleteMessagesInRange6peerId9namespace03minH003maxH012forEachMediayAA04PeerH0V_s5Int32VA2MyAA0N0_pcSgtF");
    deleteRange(peerNamespace, peer, messageNamespace, 1, maxId, NULL, NULL, transaction);
}
