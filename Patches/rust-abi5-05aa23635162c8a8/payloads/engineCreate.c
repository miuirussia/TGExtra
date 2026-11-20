#include <stdint.h>

// Generic arm64 register adapter for engineCreate: pointers/integers in x0...x3,
// pointer/integer result in x0 (ignored by callers of void functions).
// Request types and ownership: Sources/tgapi/RustBridge.{h,m}.
// The patch linker resolves Original to the checked host implementation.
__attribute__((visibility("hidden")))
extern uintptr_t Original(uintptr_t threads, uintptr_t context, uintptr_t event, uintptr_t log);
extern void *objc_lookUpClass(const char *name);
extern void *sel_registerName(const char *name);
// Use a fixed signature so Apple's C ABI passes every argument in registers.
extern uintptr_t BridgeSend(void *bridge, void *method, uintptr_t threads, uintptr_t context, uintptr_t event, uintptr_t log, void *original)
    __asm__("_objc_msgSend");

uintptr_t RustBridge_engineCreate(uintptr_t threads, uintptr_t context, uintptr_t event, uintptr_t log) {
    void *bridge = objc_lookUpClass("TGExtraRustBridge");
    if (!bridge) {
        return Original(threads, context, event, log);
    }
    void *method = sel_registerName("engineCreate:context:event:log:original:");
    return BridgeSend(bridge, method, threads, context, event, log, (void *)Original);
}
