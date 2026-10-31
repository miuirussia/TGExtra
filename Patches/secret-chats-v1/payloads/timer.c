// Swift integer arguments x0-x8, swiftself x20 and swifterror x21 are
// restored before tail-calling the reviewed host. Stack arguments stay in place.
// A missing TGExtra runtime always executes the original operation.
#include <stdint.h>
__attribute__((visibility("hidden"))) extern void Original(void);
__attribute__((visibility("hidden"))) extern void *dlsym(void *, const char *);

__attribute__((naked)) void SecretChatGate(void) {
    __asm__(
        "sub sp, sp, #112\n"
        "stp x0, x1, [sp]\n"
        "stp x2, x3, [sp, #16]\n"
        "stp x4, x5, [sp, #32]\n"
        "stp x6, x7, [sp, #48]\n"
        "stp x8, x20, [sp, #64]\n"
        "stp x21, x22, [sp, #80]\n"
        "stp x29, x30, [sp, #96]\n"
        "add x29, sp, #96\n"
        "mov x0, #-2\n"
        "adrp x1, 1f@PAGE\n"
        "add x1, x1, 1f@PAGEOFF\n"
        "bl _dlsym\n"
        "cbz x0, 2f\n"
        "mov x16, x0\n"
        "ldr x0, [sp, #72]\n"
        "ldr w1, [sp]\n"
        "ldr x2, [sp, #8]\n"
        "ldr w3, [sp, #16]\n"
        "ldr w4, [sp, #20]\n"
        "blr x16\n"
        "mov w16, w0\n"
        "b 3f\n"
        "2: mov w16, #0\n"
        "3: ldp x0, x1, [sp]\n"
        "ldp x2, x3, [sp, #16]\n"
        "ldp x4, x5, [sp, #32]\n"
        "ldp x6, x7, [sp, #48]\n"
        "ldp x8, x20, [sp, #64]\n"
        "ldp x21, x22, [sp, #80]\n"
        "ldp x29, x30, [sp, #96]\n"
        "add sp, sp, #112\n"
        "cbnz w16, 4f\n"
        "b _Original\n"
        "4: mov x0, #0\n"
        "ret\n"
        ".section __TEXT,__cstring,cstring_literals\n"
        "1: .asciz \"TGExtraSecretChatHandleExpiry\"\n"
        ".text\n"
    );
}
