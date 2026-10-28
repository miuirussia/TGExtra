#include <dlfcn.h>
#include <stdint.h>

// The patch linker resolves Original to Telegram's checked constructor parser.
__attribute__((visibility("hidden")))
extern void *Original(void *reader, int32_t signature, uint16_t expectedType);

typedef void *(*ConstructorBridge)(void *, int32_t, uint16_t, void *original);

void *NativeTL_constructor(void *reader, int32_t signature, uint16_t expectedType) {
    ConstructorBridge bridge = (ConstructorBridge)dlsym(RTLD_DEFAULT, "TGExtraNativeConstructorBridge");
    if (bridge) {
        return bridge(reader, signature, expectedType, (void *)Original);
    }
    return Original(reader, signature, expectedType);
}
