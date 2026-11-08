#import "include/Tweak.h"
#import "../tgapi/Logger/Logger.h"
#include <dlfcn.h>

typedef struct { void *object; const void *witness; } TGExtraClassExistential;
typedef void * __attribute__((swiftcall)) (*TransactionFunction)(BOOL, BOOL, void *, void *, uintptr_t, uintptr_t, intptr_t, const void *, void * __attribute__((swift_context)));
typedef TGExtraClassExistential __attribute__((swiftcall)) (*StartFunction)(void *, void *, void *, void *, void *, void *, void * __attribute__((swift_context)));
typedef TGExtraClassExistential __attribute__((swiftcall)) (*GetPeerFunction)(uint32_t, int64_t, void * __attribute__((swift_context)));
typedef uintptr_t __attribute__((swiftcall)) (*EnginePeerFunction)(void *, const void *);
typedef void __attribute__((swiftcall)) (*ProfileActionFunction)(uintptr_t, bool, void * __attribute__((swift_context)));
typedef void * __attribute__((swiftcall)) (*GetterFunction)(void * __attribute__((swift_context)));
typedef void * __attribute__((swiftcall)) (*RefreshFunction)(int64_t, int64_t, uint8_t, void * __attribute__((swift_context)));
typedef void __attribute__((swiftcall)) (*SetDisposableFunction)(void *, const void *, void * __attribute__((swift_context)));
typedef void __attribute__((swiftcall)) (*DisposeFunction)(void * __attribute__((swift_context)));

extern void TGExtraProfileLookupBody(void *context, void *transaction);
extern void TGExtraProfileRefreshFinished(void *context, BOOL success);

void TGExtraLogProfileFailure(int64_t userId, NSString *reason) {
    customLog(@"Ghost profile: open failed peer=%lld reason=%@", (long long)userId, reason);
}

static void __attribute__((swiftcall)) lookupBody(void *result __attribute__((swift_indirect_result)), void *transaction, void *context __attribute__((swift_context))) {
    TGExtraProfileLookupBody(context, transaction);
}

BOOL TGExtraProfileLookupAvailable(void) {
    return dlsym(RTLD_DEFAULT, "$s7PostboxAAC11transaction15userInteractive14ignoreDisabled_4file4line14SwiftSignalKit0J0CyxAH7NoErrorOGSb_SbxAA11TransactionCcSSSitlF") &&
        dlsym(RTLD_DEFAULT, "$s14SwiftSignalKit0B0C5start4next5error9completedAA10Disposable_pyxcSg_yq_cSgyycSgtF") &&
        dlsym(RTLD_DEFAULT, "$s7Postbox11TransactionC7getPeeryAA0D0_pSgAA0D2IdVF") &&
        dlsym(RTLD_DEFAULT, "$s12TelegramCore10EnginePeerOyAC7Postbox0D0_pcfC") &&
        // Require the host's own type metadata alongside its callable exports.
        dlsym(RTLD_DEFAULT, "$s7Postbox6PeerIdVN") &&
        dlsym(RTLD_DEFAULT, "$s12TelegramCore10EnginePeerON") &&
        dlsym(RTLD_DEFAULT, "swift_release");
}

void TGExtraRunProfileLookup(void *postbox, void *context, const void *voidMetadata) {
    TransactionFunction transaction = dlsym(RTLD_DEFAULT, "$s7PostboxAAC11transaction15userInteractive14ignoreDisabled_4file4line14SwiftSignalKit0J0CyxAH7NoErrorOGSb_SbxAA11TransactionCcSSSitlF");
    StartFunction start = dlsym(RTLD_DEFAULT, "$s14SwiftSignalKit0B0C5start4next5error9completedAA10Disposable_pyxcSg_yq_cSgyycSgtF");
    void (*release)(void *) = dlsym(RTLD_DEFAULT, "swift_release");
    void *signal = transaction(NO, NO, lookupBody, context, 0, (uintptr_t)0xe000000000000000ULL, 0, voidMetadata, postbox);
    TGExtraClassExistential disposable = start(NULL, NULL, NULL, NULL, NULL, NULL, signal);
    // The transaction retains its callback; releasing this token does not cancel it.
    release(disposable.object);
    release(signal);
}

BOOL TGExtraCopyProfilePeer(void *transaction, int64_t userId, void *result) {
    GetPeerFunction getPeer = dlsym(RTLD_DEFAULT, "$s7Postbox11TransactionC7getPeeryAA0D0_pSgAA0D2IdVF");
    EnginePeerFunction makePeer = dlsym(RTLD_DEFAULT, "$s12TelegramCore10EnginePeerOyAC7Postbox0D0_pcfC");
    // Namespace zero is CloudUser; do not resolve usernames or another peer kind.
    TGExtraClassExistential peer = getPeer(0, userId, transaction);
    if (!peer.object) return NO;
    // The initializer consumes getPeer's owned existential and returns an owned
    // enum. Its native Swift value witnesses release it after navigation.
    *(uintptr_t *)result = makePeer(peer.object, peer.witness);
    return YES;
}

BOOL TGExtraProfileRefreshAvailable(void) {
    return dlsym(RTLD_DEFAULT, "$s12TelegramCore0A6EngineC5peersAC5PeersCvg") &&
        dlsym(RTLD_DEFAULT, "$s12TelegramCore0A6EngineC5PeersC17updatedRemotePeer4peer14SwiftSignalKit0J0CyAA0cG0OAA07UpdatedfG5ErrorOGAA0G9ReferenceO_tF") &&
        dlsym(RTLD_DEFAULT, "$s14SwiftSignalKit14MetaDisposableCN") &&
        dlsym(RTLD_DEFAULT, "$s14SwiftSignalKit14MetaDisposableCACycfC") &&
        dlsym(RTLD_DEFAULT, "$s14SwiftSignalKit14MetaDisposableC3setyyAA0E0_pSgF") &&
        dlsym(RTLD_DEFAULT, "$s14SwiftSignalKit14MetaDisposableC7disposeyyF");
}

static void __attribute__((swiftcall)) refreshCompleted(void *context __attribute__((swift_context))) {
    TGExtraProfileRefreshFinished(context, YES);
}

static void __attribute__((swiftcall)) refreshFailed(const void *error, void *context __attribute__((swift_context))) {
    TGExtraProfileRefreshFinished(context, NO);
}

void *TGExtraRefreshProfilePeer(void *engine, int64_t userId, int64_t accessHash, void *context) {
    GetterFunction getPeers = dlsym(RTLD_DEFAULT, "$s12TelegramCore0A6EngineC5peersAC5PeersCvg");
    RefreshFunction refresh = dlsym(RTLD_DEFAULT, "$s12TelegramCore0A6EngineC5PeersC17updatedRemotePeer4peer14SwiftSignalKit0J0CyAA0cG0OAA07UpdatedfG5ErrorOGAA0G9ReferenceO_tF");
    GetterFunction makeToken = dlsym(RTLD_DEFAULT, "$s14SwiftSignalKit14MetaDisposableCACycfC");
    SetDisposableFunction set = dlsym(RTLD_DEFAULT, "$s14SwiftSignalKit14MetaDisposableC3setyyAA0E0_pSgF");
    StartFunction start = dlsym(RTLD_DEFAULT, "$s14SwiftSignalKit0B0C5start4next5error9completedAA10Disposable_pyxcSg_yq_cSgyycSgtF");
    void (*release)(void *) = dlsym(RTLD_DEFAULT, "swift_release");
    void *peers = getPeers(engine);
    // PeerReference.user(id:accessHash:) lowers to two Int64s and tag zero.
    // Only reuse a personal access hash captured in this source account.
    void *signal = refresh(userId, accessHash, 0, peers);
    void *token = makeToken(dlsym(RTLD_DEFAULT, "$s14SwiftSignalKit14MetaDisposableCN"));
    TGExtraClassExistential disposable = start(NULL, NULL, refreshFailed, context, refreshCompleted, context, signal);
    set(disposable.object, disposable.witness, token);
    release(disposable.object);
    release(signal);
    release(peers);
    return token;
}

void TGExtraDisposeProfileRefresh(void *token) {
    DisposeFunction dispose = dlsym(RTLD_DEFAULT, "$s14SwiftSignalKit14MetaDisposableC7disposeyyF");
    void (*release)(void *) = dlsym(RTLD_DEFAULT, "swift_release");
    dispose(token);
    release(token);
}

void TGExtraInvokeProfileAction(const void *function, const void *context, const void *peer) {
    ProfileActionFunction action = (ProfileActionFunction)function;
    action(*(const uintptr_t *)peer, false, (void *)context);
}
