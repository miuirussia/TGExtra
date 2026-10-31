#import "TemporaryFiles.h"
#import "Constants.h"

static NSArray<NSString *> *uploadDirectories(void) {
    return @[FILE_PICKER_PATH, @"TGExtraVideoToVoice", @"TGExtraVideoToRound"];
}

static NSURL *temporaryRoot(void) {
    return [[NSURL fileURLWithPath:NSTemporaryDirectory() isDirectory:YES] URLByResolvingSymlinksInPath];
}

static BOOL isExportFile(NSString *name) {
    return [name hasPrefix:@"TGExtraPaid-"] || [name hasPrefix:@"TGExtraStory-"] ||
           [name hasPrefix:@"TGExtraStoryInput-"];
}

static dispatch_queue_t cleanupQueue(void) {
    static dispatch_queue_t queue;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ queue = dispatch_queue_create("TGExtra.TemporaryFiles", DISPATCH_QUEUE_SERIAL); });
    return queue;
}

static BOOL isMissingFile(NSError *error) {
    return [error.domain isEqual:NSCocoaErrorDomain] &&
        (error.code == NSFileNoSuchFileError || error.code == NSFileReadNoSuchFileError);
}

@interface NSObject (TGExtraLegacyLogContainers)
+ (id)bundleProxyForCurrentProcess;
- (NSDictionary *)groupContainerURLs;
@end

static NSArray<NSURL *> *legacyLogFiles(void) {
    NSURL *documents = [[NSURL fileURLWithPath:NSHomeDirectory() isDirectory:YES]
        URLByAppendingPathComponent:@"Documents" isDirectory:YES];
    NSMutableArray *files = [NSMutableArray arrayWithObjects:
        [documents URLByAppendingPathComponent:@"chocoLogs.txt"],
        [documents URLByAppendingPathComponent:@"tgextra_debug.txt"], nil];
    // Older TGExtra versions wrote unbounded logs in the app's shared container.
    // Discover only this app's containers and address its exact legacy filename.
    @try {
        Class proxyClass = NSClassFromString(@"LSBundleProxy");
        NSString *bundle = NSBundle.mainBundle.bundleIdentifier;
        if (![proxyClass respondsToSelector:@selector(bundleProxyForCurrentProcess)] || !bundle.length) return files;
        id proxy = [proxyClass bundleProxyForCurrentProcess];
        if (![proxy respondsToSelector:@selector(groupContainerURLs)]) return files;
        id containers = [proxy groupContainerURLs];
        if (![containers isKindOfClass:NSDictionary.class]) return files;
        for (id container in [containers allValues]) {
            if (![container isKindOfClass:NSURL.class] || ![container isFileURL]) continue;
            NSURL *root = [container URLByResolvingSymlinksInPath];
            NSURL *directory = [root URLByAppendingPathComponent:@"group.choco.whore" isDirectory:YES];
            if (![directory.URLByResolvingSymlinksInPath.path isEqual:directory.path]) continue;
            NSURL *url = [directory URLByAppendingPathComponent:[bundle stringByAppendingPathExtension:@"txt"]];
            if (![files containsObject:url]) [files addObject:url];
        }
    } @catch (NSException *exception) {
        // Launch Services is optional; Documents logs can still be cleaned.
    }
    return files;
}

static NSArray<NSURL *> *cleanupTargets(NSError **error) {
    NSArray *files = [NSFileManager.defaultManager contentsOfDirectoryAtURL:temporaryRoot()
        includingPropertiesForKeys:nil options:0 error:error];
    NSMutableArray *targets = [NSMutableArray new];
    for (NSURL *url in files) {
        NSString *name = url.lastPathComponent;
        if ([uploadDirectories() containsObject:name] || isExportFile(name) ||
            [name isEqual:@"TGExtraForwardCopies"]) [targets addObject:url];
    }
    for (NSURL *url in legacyLogFiles()) {
        NSError *readError = nil;
        NSDictionary *attributes = [NSFileManager.defaultManager attributesOfItemAtPath:url.path error:&readError];
        if (!attributes) {
            if (!isMissingFile(readError) && error && !*error) *error = readError;
            continue;
        }
        NSString *type = attributes[NSFileType];
        if ([type isEqual:NSFileTypeRegular] || [type isEqual:NSFileTypeSymbolicLink]) [targets addObject:url];
    }
    return targets;
}

static void removeEmptyParents(NSURL *url, NSURL *root) {
    NSFileManager *manager = NSFileManager.defaultManager;
    while (![url.path isEqual:root.path] && [url.path hasPrefix:[root.path stringByAppendingString:@"/"]]) {
        NSArray *contents = [manager contentsOfDirectoryAtURL:url includingPropertiesForKeys:nil options:0 error:NULL];
        if (!contents || contents.count || ![manager removeItemAtURL:url error:NULL]) break;
        url = url.URLByDeletingLastPathComponent;
    }
}

@implementation TGExtraTemporaryFiles
+ (void)didCopyFromURL:(NSURL *)source toURL:(NSURL *)destination {
    if (!source.isFileURL || !destination.isFileURL) return;
    // Most copies have nothing to do with TGExtra; avoid filesystem work for them.
    BOOL managed = NO;
    for (NSString *directory in uploadDirectories()) {
        if ([source.path containsString:[@"/" stringByAppendingString:[directory stringByAppendingString:@"/"]]]) {
            managed = YES;
            break;
        }
    }
    if (!managed) return;
    source = source.URLByResolvingSymlinksInPath;
    destination = destination.URLByResolvingSymlinksInPath;
    // MediaBox has a complete copy before the host marks its resource available.
    // Never consume a source for an unrelated copy (share sheet, preview, etc.).
    if (![destination.URLByDeletingLastPathComponent.lastPathComponent isEqual:@"media"]) return;
    NSURL *root = temporaryRoot();
    if ([destination.path hasPrefix:[root.path stringByAppendingString:@"/"]]) return;
    for (NSString *directory in uploadDirectories()) {
        NSURL *uploadRoot = [root URLByAppendingPathComponent:directory isDirectory:YES];
        if (![source.path hasPrefix:[uploadRoot.path stringByAppendingString:@"/"]]) continue;
        if ([NSFileManager.defaultManager removeItemAtURL:source error:NULL]) {
            removeEmptyParents(source.URLByDeletingLastPathComponent, uploadRoot);
        }
        return;
    }
}

+ (void)removeAbandonedExports {
    // Snapshot at tweak initialization, before this process can create exports.
    // Upload sources are deliberately excluded: pending sends survive a restart.
    NSURL *root = temporaryRoot();
    NSArray<NSURL *> *files = [NSFileManager.defaultManager contentsOfDirectoryAtURL:root
        includingPropertiesForKeys:nil options:0 error:NULL];
    NSMutableArray<NSURL *> *abandoned = [NSMutableArray new];
    for (NSURL *url in files) {
        if (isExportFile(url.lastPathComponent)) {
            [abandoned addObject:url];
        } else if ([url.lastPathComponent isEqual:@"TGExtraForwardCopies"]) {
            [abandoned addObjectsFromArray:[NSFileManager.defaultManager contentsOfDirectoryAtURL:url
                includingPropertiesForKeys:nil options:0 error:NULL] ?: @[]];
        }
    }
    dispatch_async(cleanupQueue(), ^{
        for (NSURL *url in abandoned) [NSFileManager.defaultManager removeItemAtURL:url error:NULL];
    });
}

+ (void)usageWithCompletion:(void (^)(NSUInteger, unsigned long long, NSError *))completion {
    dispatch_async(cleanupQueue(), ^{
        __block NSError *error = nil;
        __block NSUInteger count = 0;
        __block unsigned long long bytes = 0;
        NSArray *keys = @[NSURLIsDirectoryKey, NSURLIsSymbolicLinkKey, NSURLFileSizeKey];
        void (^measure)(NSURL *) = ^(NSURL *url) {
            NSError *readError = nil;
            NSDictionary *values = [url resourceValuesForKeys:keys error:&readError];
            if (!values) {
                if (!isMissingFile(readError) && !error) error = readError;
                return;
            }
            if (![values[NSURLIsDirectoryKey] boolValue] || [values[NSURLIsSymbolicLinkKey] boolValue]) {
                count++;
                bytes += [values[NSURLFileSizeKey] unsignedLongLongValue];
            }
        };
        for (NSURL *url in cleanupTargets(&error)) {
            measure(url);
            NSNumber *directory = nil, *symlink = nil;
            [url getResourceValue:&directory forKey:NSURLIsDirectoryKey error:NULL];
            [url getResourceValue:&symlink forKey:NSURLIsSymbolicLinkKey error:NULL];
            if (!directory.boolValue || symlink.boolValue) continue;
            NSDirectoryEnumerator *files = [NSFileManager.defaultManager enumeratorAtURL:url
                includingPropertiesForKeys:keys options:0 errorHandler:^BOOL(NSURL *path, NSError *readError) {
                    if (!isMissingFile(readError) && !error) error = readError;
                    return YES;
                }];
            for (NSURL *file in files) measure(file);
        }
        dispatch_async(dispatch_get_main_queue(), ^{ completion(count, bytes, error); });
    });
}

+ (void)clearWithCompletion:(void (^)(NSError *))completion {
    dispatch_async(cleanupQueue(), ^{
        NSError *error = nil;
        for (NSURL *url in cleanupTargets(&error)) {
            NSError *removalError = nil;
            BOOL removed = [NSFileManager.defaultManager removeItemAtURL:url error:&removalError];
            if (removed && [url.URLByDeletingLastPathComponent.lastPathComponent isEqual:@"group.choco.whore"]) {
                removeEmptyParents(url.URLByDeletingLastPathComponent, url.URLByDeletingLastPathComponent.URLByDeletingLastPathComponent);
            }
            if (!removed && !isMissingFile(removalError)) {
                if (!error) error = removalError;
            }
        }
        dispatch_async(dispatch_get_main_queue(), ^{ completion(error); });
    });
}
@end
