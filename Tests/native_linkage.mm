#import "../Sources/tgapiC/include/NativeTL.h"
#include <assert.h>

// Link an Objective-C++ caller against NativeTL.m, as the Logos hooks do.
int main(void) {
    @autoreleasepool {
        assert(!TGExtraNativeReady());
        assert(TGExtraNativePacket([NSData data], nil, 0, nil) == nil);
        id marker = [NSObject new];
        id previous = TGExtraNativeBegin(marker);
        assert(previous == nil);
        assert(TGExtraNativeBegin(nil) == marker);
        TGExtraNativeEnd(previous);
    }
    return 0;
}
