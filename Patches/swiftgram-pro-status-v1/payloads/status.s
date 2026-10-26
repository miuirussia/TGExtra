// SGStatus Decodable witness, successful return only:
// x0 = decoded Int64, x19 = indirect result address, x21 = nil Swift error.
// Keep the original decoder and its error path. x8 is caller-saved scratch.
.text
.p2align 2
mov x8, #2
cmp x0, x8
csel x0, x0, x8, ge
str x0, [x19]
// ipatch links this branch to the witness's original epilogue at +28.
b .
