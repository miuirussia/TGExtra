#include <stdint.h>

#define MINIMUM_STATUS 2

// C meaning of the successful-store patch. The existing witness handles errors
// before reaching this insertion point, so failed decoding never changes storage.
static inline int64_t decodedStatus(int64_t status) {
    return status < MINIMUM_STATUS ? MINIMUM_STATUS : status;
}

#define STRINGIFY_VALUE(value) #value
#define STRINGIFY(value) STRINGIFY_VALUE(value)

// This is an insertion inside a Swift witness, not a C-callable function:
// x0 holds status, x19 points to result storage, x21 is the Swift error register.
// An ordinary C prologue/return would corrupt the enclosing Swift stack frame.
// Keep this adapter at 20 bytes; iPatch links its last branch to witness +28.
__attribute__((naked)) void ProStatusPayload(void) {
    __asm__(
        "mov x8, #" STRINGIFY(MINIMUM_STATUS) "\n"
        "cmp x0, x8\n"
        "csel x0, x0, x8, ge\n"
        "str x0, [x19]\n"
        "b .\n"
    );
}
