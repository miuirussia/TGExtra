#include <dlfcn.h>

// Only root calls are redirected; nested decoding stays in Telegram's parser.
__attribute__((visibility("hidden")))
extern void *Original(void *reader, const void *functionInfo);

typedef void *(*ResultBridge)(void *, const void *, void *original);

void *NativeTL_result(void *reader, const void *functionInfo) {
    ResultBridge bridge = (ResultBridge)dlsym(RTLD_DEFAULT, "TGExtraNativeResultBridge");
    if (bridge) {
        return bridge(reader, functionInfo, (void *)Original);
    }
    return Original(reader, functionInfo);
}
