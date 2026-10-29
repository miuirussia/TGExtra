#import "Logger.h"

static dispatch_queue_t logQueue(void) {
    static dispatch_queue_t queue;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ queue = dispatch_queue_create("TGExtra.Log", DISPATCH_QUEUE_SERIAL); });
    return queue;
}

static NSString *logPath(void) {
#ifdef TGEXTRA_TESTING
    return NSProcessInfo.processInfo.environment[@"TGEXTRA_TEST_LOG_PATH"];
#else
    return [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Caches/TGExtra/Debug.log"];
#endif
}

static void appendLog(NSString *message) {
    dispatch_async(logQueue(), ^{
        NSString *path = logPath();
        if (!path) return;
        NSFileManager *manager = NSFileManager.defaultManager;
        if (![manager createDirectoryAtPath:path.stringByDeletingLastPathComponent
               withIntermediateDirectories:YES attributes:nil error:NULL]) return;
        if (![manager fileExistsAtPath:path]) [manager createFileAtPath:path contents:nil attributes:nil];
        NSFileHandle *file = [NSFileHandle fileHandleForWritingAtPath:path];
        if (!file) return;
        @try {
            if ([file seekToEndOfFile] > 1024 * 1024) [file truncateFileAtOffset:0];
            NSString *line = [NSString stringWithFormat:@"%@ %@\n", NSDate.date, message];
            [file writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
        } @catch (NSException *exception) {
            NSLog(@"[TGExtra] Log write failed: %@", exception.reason);
        } @finally {
            [file closeFile];
        }
    });
}

void customLog(NSString *format, ...) {
    va_list args;
    va_start(args, format);
    NSString *message = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);
    appendLog(message);
}

void customLog2(NSString *format, ...) {
    va_list args;
    va_start(args, format);
    NSString *message = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);
    appendLog(message);
}

NSString *TGExtraReadLog(void) {
    __block NSString *text;
    dispatch_sync(logQueue(), ^{
        NSString *path = logPath();
        if (path) text = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:NULL];
    });
    return text ?: @"";
}

void TGExtraClearLog(void) {
    dispatch_sync(logQueue(), ^{
        NSString *path = logPath();
        if (path) [@"" writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:NULL];
    });
}
