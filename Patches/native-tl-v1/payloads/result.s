// One bridge per root decode. Nested parser calls stay inside Telegram.
// Missing tweak: tail-call the original parser with the untouched arguments.
.text
.p2align 2
.globl _NativeTL_result
_NativeTL_result:
sub sp, sp, #48
stp x0, x1, [sp]
str x2, [sp, #16]
stp x29, x30, [sp, #32]
mov x0, #-2
adrp x1, Lsymbol@PAGE
add x1, x1, Lsymbol@PAGEOFF
bl _dlsym
mov x16, x0
ldp x0, x1, [sp]
ldr x2, [sp, #16]
ldp x29, x30, [sp, #32]
add sp, sp, #48
cbz x16, Lfallback
adrp x2, _Original@PAGE
add x2, x2, _Original@PAGEOFF
br x16
Lfallback:
b _Original
Lsymbol:
.asciz "TGExtraNativeResultBridge"
.p2align 2
