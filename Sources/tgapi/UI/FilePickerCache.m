#import "FilePickerCache.h"
#import "../Constants.h"

@implementation TGExtraFilePickerCache
static dispatch_queue_t cacheQueue(void) {
    static dispatch_queue_t queue;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ queue = dispatch_queue_create("TGExtra.FilePickerCache", DISPATCH_QUEUE_SERIAL); });
    return queue;
}
static NSURL *cacheURL(void) {
    return [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:FILE_PICKER_PATH] isDirectory:YES];
}
+ (void)sizeWithCompletion:(void (^)(NSString *))completion {
    dispatch_async(cacheQueue(), ^{
        unsigned long long total = 0;
        NSDirectoryEnumerator *files = [NSFileManager.defaultManager enumeratorAtURL:cacheURL()
            includingPropertiesForKeys:@[NSURLIsRegularFileKey, NSURLFileSizeKey] options:0 errorHandler:nil];
        for (NSURL *url in files) {
            NSDictionary *values = [url resourceValuesForKeys:@[NSURLIsRegularFileKey, NSURLFileSizeKey] error:NULL];
            if ([values[NSURLIsRegularFileKey] boolValue]) total += [values[NSURLFileSizeKey] unsignedLongLongValue];
        }
        NSString *size = total >= 1024ULL * 1024 * 1024
            ? [NSString stringWithFormat:@"%.2f GB", total / (1024.0 * 1024.0 * 1024.0)]
            : [NSString stringWithFormat:@"%.2f MB", total / (1024.0 * 1024.0)];
        dispatch_async(dispatch_get_main_queue(), ^{ completion(size); });
    });
}
+ (void)clearWithCompletion:(void (^)(NSError *))completion {
    dispatch_async(cacheQueue(), ^{
        NSError *error = nil;
        if (![NSFileManager.defaultManager removeItemAtURL:cacheURL() error:&error] &&
            [error.domain isEqualToString:NSCocoaErrorDomain] && error.code == NSFileNoSuchFileError) error = nil;
        dispatch_async(dispatch_get_main_queue(), ^{ completion(error); });
    });
}
@end
