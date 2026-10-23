#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <objc/message.h>
#include <stdint.h>
extern uintptr_t RustThunk1(uintptr_t);
extern uintptr_t RustThunk2(uintptr_t, uintptr_t);
extern uintptr_t RustThunk3(uintptr_t, uintptr_t, uintptr_t);
extern uintptr_t RustThunk4(uintptr_t, uintptr_t, uintptr_t, uintptr_t);
extern uintptr_t RustThunkFallback(uintptr_t, uintptr_t, uintptr_t, uintptr_t);
uintptr_t RustOriginal1(uintptr_t a) { return a+11; }
uintptr_t RustOriginal2(uintptr_t a, uintptr_t b) { return a+2*b+13; }
uintptr_t RustOriginal3(uintptr_t a, uintptr_t b, uintptr_t c) { return a+2*b+3*c+17; }
uintptr_t RustOriginal4(uintptr_t a, uintptr_t b, uintptr_t c, uintptr_t d) { return a+2*b+3*c+4*d+19; }
@interface TGExtraRustBridge : NSObject
@end
@implementation TGExtraRustBridge
+ (uintptr_t)one:(uintptr_t)a original:(uintptr_t (*)(uintptr_t))original { return original(a)+101; }
+ (uintptr_t)two:(uintptr_t)a b:(uintptr_t)b original:(uintptr_t (*)(uintptr_t,uintptr_t))original { return original(a,b)+103; }
+ (uintptr_t)three:(uintptr_t)a b:(uintptr_t)b c:(uintptr_t)c original:(uintptr_t (*)(uintptr_t,uintptr_t,uintptr_t))original { return original(a,b,c)+107; }
+ (uintptr_t)four:(uintptr_t)a b:(uintptr_t)b c:(uintptr_t)c d:(uintptr_t)d original:(uintptr_t (*)(uintptr_t,uintptr_t,uintptr_t,uintptr_t))original { return original(a,b,c,d)+109; }
@end
int main(void) {
    // Ensure the linker emits the same three ordinary ObjC import stubs used by
    // the offline IPA patch. The generated test executable retains no Telegram.
    id cls = objc_lookUpClass("TGExtraRustBridge");
    ((id (*)(id, SEL))objc_msgSend)(cls, sel_registerName("class"));
    NSCAssert(RustThunk1(1001)==RustOriginal1(1001)+101, @"one C argument and original pointer");
    NSCAssert(RustThunk2(1001,2002)==RustOriginal2(1001,2002)+103, @"two C arguments and original pointer");
    NSCAssert(RustThunk3(1001,2002,3003)==RustOriginal3(1001,2002,3003)+107, @"three C arguments and original pointer");
    NSCAssert(RustThunk4(1001,2002,3003,4004)==RustOriginal4(1001,2002,3003,4004)+109, @"four C arguments and original pointer");
    NSCAssert(RustThunkFallback(1001,2002,3003,4004)==RustOriginal4(1001,2002,3003,4004), @"missing bridge must preserve original execution");
    puts("PASS native arm64 offline thunks: arguments, return values, original calls and missing-tweak fallback");
}
