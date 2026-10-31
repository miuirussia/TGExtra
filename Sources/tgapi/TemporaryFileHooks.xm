#import "TemporaryFiles.h"

%hook NSFileManager
- (BOOL)copyItemAtURL:(NSURL *)source toURL:(NSURL *)destination error:(NSError **)error {
    BOOL copied = %orig;
    if (copied) [TGExtraTemporaryFiles didCopyFromURL:source toURL:destination];
    return copied;
}
- (BOOL)copyItemAtPath:(NSString *)source toPath:(NSString *)destination error:(NSError **)error {
    BOOL copied = %orig;
    if (copied) [TGExtraTemporaryFiles didCopyFromURL:[NSURL fileURLWithPath:source]
                                             toURL:[NSURL fileURLWithPath:destination]];
    return copied;
}
%end

%ctor {
    %init;
#ifndef TGEXTRA_TESTING
    if (![NSBundle.mainBundle.bundlePath.pathExtension isEqual:@"appex"]) {
        [TGExtraTemporaryFiles removeAbandonedExports];
    }
#endif
}
