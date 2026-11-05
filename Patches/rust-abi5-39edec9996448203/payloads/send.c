#include <stdint.h>

// Generic arm64 register adapter for send: pointers/integers in x0...x3,
// pointer/integer result in x0 (ignored by callers of void functions).
// Request types and ownership: Sources/tgapi/RustBridge.{h,m}.
// The patch linker resolves Original to the checked host implementation.
__attribute__((visibility("hidden")))
extern uintptr_t Original(uintptr_t engine, uintptr_t session, uintptr_t request);
extern void *objc_lookUpClass(const char *name);
extern void *sel_registerName(const char *name);
// Use a fixed signature so Apple's C ABI passes every argument in registers.
extern uintptr_t BridgeSend(void *bridge, void *method, uintptr_t engine, uintptr_t session, uintptr_t request, void *original)
    __asm__("_objc_msgSend");

uintptr_t RustBridge_send(uintptr_t engine, uintptr_t session, uintptr_t request) {
    void *bridge = objc_lookUpClass("TGExtraRustBridge");
    if (!bridge) {
        return Original(engine, session, request);
    }
    void *method = sel_registerName("send:session:request:original:");
    return BridgeSend(bridge, method, engine, session, request, (void *)Original);
}
