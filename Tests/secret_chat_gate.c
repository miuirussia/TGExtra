// Run each production payload with the reviewed integer/Swift calling registers.
#include <assert.h>
#include <stdint.h>
#include <stdio.h>

extern uintptr_t SecretChatGate(uintptr_t, uintptr_t, uintptr_t, uintptr_t,
                                uintptr_t, uintptr_t, uintptr_t, uintptr_t);
uintptr_t captured[11];
static int block, calls, observedEvent, observedNamespace;

#ifndef MISSING_RUNTIME
int32_t TGExtraSecretChatShouldBlock(int32_t event, int32_t peerNamespace) {
    observedEvent = event;
    observedNamespace = peerNamespace;
    return block;
}
#endif

__attribute__((naked)) void Original(void) {
    __asm__(
        "adrp x9, _captured@PAGE\n"
        "add x9, x9, _captured@PAGEOFF\n"
        "stp x0, x1, [x9]\n"
        "stp x2, x3, [x9, #16]\n"
        "stp x4, x5, [x9, #32]\n"
        "stp x6, x7, [x9, #48]\n"
        "stp x8, x20, [x9, #64]\n"
        "str x21, [x9, #80]\n"
        "b _OriginalResult\n"
    );
}

uintptr_t OriginalResult(void) { calls++; return 0x77; }

__attribute__((naked)) uintptr_t InvokeGate(void) {
    __asm__(
        "stp x20, x21, [sp, #-32]!\n"
        "stp x29, x30, [sp, #16]\n"
        "add x29, sp, #16\n"
        "mov x0, #3\n" "mov x1, #4\n" "mov x2, #5\n" "mov x3, #6\n"
        "mov x4, #7\n" "mov x5, #8\n" "mov x6, #9\n" "mov x7, #10\n"
        "mov x8, #11\n" "mov x20, #12\n" "mov x21, #13\n"
        "bl _SecretChatGate\n"
        "ldp x29, x30, [sp, #16]\n"
        "ldp x20, x21, [sp], #32\n"
        "ret\n"
    );
}

int main(void) {
    assert(InvokeGate() == 0x77 && calls == 1);
    for (int i = 0; i < 11; i++) assert(captured[i] == (uintptr_t)(i+3));
#ifndef MISSING_RUNTIME
    assert(observedEvent == EVENT);
    assert(observedNamespace == (EVENT == 2 ? 3 : EVENT == 3 ? 4 : 0));
    block = 1;
    assert(InvokeGate() == 0 && calls == 1);
#else
    block = 1;
    assert(InvokeGate() == 0x77 && calls == 2);
#endif
    puts("PASS secret-chat bridge: arguments, swiftself, swifterror, indirect result, block/fallback");
}
