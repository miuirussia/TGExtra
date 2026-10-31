#!/usr/bin/env python3
"""Exercise real file-copy hooks, restart cleanup, usage and forced deletion."""
from pathlib import Path
import os
import subprocess
import tempfile

root = Path(__file__).resolve().parent.parent
logos = Path(os.environ.get('LOGOS_PL', root / '.build/theos/bin/logos.pl'))
support = r'''
#import <Foundation/Foundation.h>
static NSString *testTemporaryPath;
static NSString *testHomePath;
static id testGroupContainers;
static BOOL testProxyAvailable = YES, testProxyThrows;
@interface TestCleanupBundle : NSObject
+ (instancetype)mainBundle;
- (NSString *)bundleIdentifier;
@end
@implementation TestCleanupBundle
+ (instancetype)mainBundle { return [self new]; }
- (NSString *)bundleIdentifier { return @"test.cleanup"; }
@end
@interface TestLegacyProxy : NSObject
+ (instancetype)bundleProxyForCurrentProcess;
- (id)groupContainerURLs;
@end
@implementation TestLegacyProxy
+ (instancetype)bundleProxyForCurrentProcess {
    if (testProxyThrows) [NSException raise:@"Unavailable" format:@"Launch Services unavailable"];
    return [self new];
}
- (id)groupContainerURLs { return testGroupContainers; }
@end
static Class testClassFromString(NSString *name) {
    if ([name isEqual:@"LSBundleProxy"]) return testProxyAvailable ? TestLegacyProxy.class : Nil;
    return NSClassFromString(name);
}
static NSString *testHomeDirectory(void) { return testHomePath ?: @"/nonexistent/tgextra-test-home"; }
static NSString *testTemporaryDirectory(void) { return testTemporaryPath ?: NSTemporaryDirectory(); }
#define NSTemporaryDirectory testTemporaryDirectory
#define NSHomeDirectory testHomeDirectory
#define NSBundle TestCleanupBundle
#define NSClassFromString testClassFromString
#import "TemporaryFiles.m"

static NSURL *writeFile(NSURL *root, NSString *path, NSString *text) {
    NSURL *url = [root URLByAppendingPathComponent:path];
    NSCAssert([NSFileManager.defaultManager createDirectoryAtURL:url.URLByDeletingLastPathComponent
        withIntermediateDirectories:YES attributes:nil error:NULL], @"Create fixture directory");
    NSCAssert([text writeToURL:url atomically:YES encoding:NSUTF8StringEncoding error:NULL], @"Write fixture");
    return url;
}
static BOOL exists(NSURL *url) { return [NSFileManager.defaultManager fileExistsAtPath:url.path]; }
static void waitFor(BOOL (^condition)(void)) {
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:5];
    while (!condition() && deadline.timeIntervalSinceNow > 0) {
        [NSRunLoop.mainRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
    }
    NSCAssert(condition(), @"Background cleanup completes");
}
int main(void) { @autoreleasepool {
    NSURL *base = [NSURL fileURLWithPath:[@"/private/tmp" stringByAppendingPathComponent:NSUUID.UUID.UUIDString]];
    NSURL *temp = [base URLByAppendingPathComponent:@"tmp"];
    testTemporaryPath = temp.path;
    testHomePath = base.path;
    NSFileManager *manager = NSFileManager.defaultManager;
    NSURL *media = [base URLByAppendingPathComponent:@"account/postbox/media"];
    [manager createDirectoryAtURL:media withIntermediateDirectories:YES attributes:nil error:NULL];

    NSUInteger serial = 0;
    for (NSString *directory in uploadDirectories()) {
        NSURL *source = writeFile(temp, [directory stringByAppendingPathComponent:@"unique/clip"], @"complete payload");
        NSURL *destination = [media URLByAppendingPathComponent:[NSString stringWithFormat:@"file-%lu", (unsigned long)serial++]];
        NSCAssert([manager copyItemAtURL:source toURL:destination error:NULL], @"Copy to MediaBox succeeds");
        NSCAssert(!exists(source) && !exists(source.URLByDeletingLastPathComponent), @"Release copied source and empty UUID directory");
        NSCAssert([[NSString stringWithContentsOfURL:destination encoding:NSUTF8StringEncoding error:NULL]
            isEqual:@"complete payload"], @"Preserve the host's complete cache file");
    }
    NSURL *source = writeFile(temp, @"TGExtraVideoToRound/path.mp4", @"path copy");
    NSCAssert([manager copyItemAtPath:source.path toPath:[media URLByAppendingPathComponent:@"path"].path error:NULL] &&
        !exists(source), @"Path-based copies consume their sources too");
    source = writeFile(temp, @"TGExtraVideoToVoice/pending/voice.m4a", @"pending");
    NSURL *occupied = writeFile(media, @"occupied", @"existing cache");
    NSCAssert(![manager copyItemAtURL:source toURL:occupied error:NULL] && exists(source), @"A failed copy preserves the pending upload");
    NSURL *share = [base URLByAppendingPathComponent:@"shared.m4a"];
    NSCAssert([manager copyItemAtURL:source toURL:share error:NULL] && exists(source), @"Preview and share copies do not consume uploads");
    NSURL *tempCopy = writeFile(temp, @"media/placeholder", @"").URLByDeletingLastPathComponent;
    NSCAssert([manager copyItemAtURL:source toURL:[tempCopy URLByAppendingPathComponent:@"preview"] error:NULL] &&
        exists(source), @"A temporary directory named media is not the persistent cache");
    NSURL *foreign = writeFile(base, @"foreign/TGExtraVideoToVoice/clip", @"foreign");
    NSCAssert([manager copyItemAtURL:foreign toURL:[media URLByAppendingPathComponent:@"foreign"] error:NULL] &&
        exists(foreign), @"Matching directory names outside the temporary root are untouched");

    NSURL *oldPaid = writeFile(temp, @"TGExtraPaid-old.mp4", @"orphan");
    NSURL *oldStory = writeFile(temp, @"TGExtraStory-old.mp4", @"orphan");
    NSURL *oldInput = writeFile(temp, @"TGExtraStoryInput-old.mp4", @"orphan");
    NSURL *oldForward = writeFile(temp, @"TGExtraForwardCopies/old/media", @"orphan");
    [TGExtraTemporaryFiles removeAbandonedExports];
    NSURL *newForward = writeFile(temp, @"TGExtraForwardCopies/new/media", @"active");
    __block BOOL measured = NO;
    [TGExtraTemporaryFiles usageWithCompletion:^(NSUInteger count, unsigned long long bytes, NSError *error) {
        NSCAssert(NSThread.isMainThread && !error, @"Usage is delivered on the main queue");
        measured = YES;
    }];
    waitFor(^BOOL { return measured; }); // The serial queue drains startup deletion first.
    NSCAssert(!exists(oldPaid) && !exists(oldStory) && !exists(oldInput) && !exists(oldForward), @"Remove interrupted exports from the previous process");
    NSCAssert(exists(source) && exists(newForward), @"Keep pending uploads and new operations during startup cleanup");

    // Use a fresh fixture for exact count/size assertions, excluding directories.
    [manager removeItemAtURL:temp error:NULL];
    writeFile(temp, @"TGExtraVideoToVoice/id/voice.m4a", @"abc");
    writeFile(temp, @"TGExtraVideoToRound/round.mp4", @"12345");
    writeFile(temp, [FILE_PICKER_PATH stringByAppendingPathComponent:@"id/file"], @"12");
    writeFile(temp, @"TGExtraPaid-current.jpg", @"1234");
    writeFile(temp, @"TGExtraStory-current.mp4", @"12");
    writeFile(temp, @"TGExtraStoryInput-current.mp4", @"123");
    writeFile(temp, @"TGExtraForwardCopies/id/media", @"123456");
    NSURL *unrelated = writeFile(temp, @"other-cache/file", @"keep");
    NSURL *similar = writeFile(temp, @"TGExtraVideoToVoiceOther/file", @"keep");
    NSURL *preferences = writeFile(base, @"Library/Application Support/TGExtra/Preferences.plist", @"settings");
    NSURL *history = writeFile(base, @"Library/Application Support/TGExtra/History.sqlite", @"history");
    NSURL *journal = writeFile(base, @"Library/Application Support/TGExtra/ForwardCopies/pending.plist", @"retry");
    NSURL *currentLog = writeFile(base, @"Library/Caches/TGExtra/Debug.log", @"current diagnostics");
    NSURL *wal = writeFile(base, @"Library/Application Support/TGExtra/History.sqlite-wal", @"journal");
    measured = NO;
    [TGExtraTemporaryFiles usageWithCompletion:^(NSUInteger count, unsigned long long bytes, NSError *error) {
        NSCAssert(!error && count == 7 && bytes == 25, @"Count only cleanup targets, recursively, with their exact bytes");
        measured = YES;
    }];
    waitFor(^BOOL { return measured; });
    NSCAssert(exists(history) && exists(unrelated), @"Measuring never deletes files");
    NSURL *oldDocumentLog = writeFile(base, @"Documents/chocoLogs.txt", @"legacy");
    NSURL *oldDebugLog = writeFile(base, @"Documents/tgextra_debug.txt", @"old");
    NSURL *groupOne = [base URLByAppendingPathComponent:@"shared-one"];
    NSURL *groupTwo = [base URLByAppendingPathComponent:@"shared-two"];
    NSURL *groupLogOne = writeFile(groupOne, @"group.choco.whore/test.cleanup.txt", @"1234");
    NSURL *groupLogTwo = writeFile(groupTwo, @"group.choco.whore/test.cleanup.txt", @"12345");
    NSURL *otherLog = writeFile(groupOne, @"group.choco.whore/other.app.txt", @"keep");
    NSURL *telegramCache = writeFile(groupOne, @"account/postbox/media/file", @"Telegram cache");
    NSURL *documentsFile = writeFile(base, @"Documents/unrelated.txt", @"keep");
    NSURL *directoryGroup = [base URLByAppendingPathComponent:@"directory-group"];
    NSURL *directoryFile = writeFile(directoryGroup, @"group.choco.whore/test.cleanup.txt/nested", @"keep");
    NSURL *symlinkGroup = [base URLByAppendingPathComponent:@"symlink-group"];
    [manager createDirectoryAtURL:symlinkGroup withIntermediateDirectories:YES attributes:nil error:NULL];
    [manager createSymbolicLinkAtURL:[symlinkGroup URLByAppendingPathComponent:@"group.choco.whore"]
        withDestinationURL:[groupOne URLByAppendingPathComponent:@"group.choco.whore"] error:NULL];
    testGroupContainers = @{@"one": groupOne, @"duplicate": groupOne, @"two": groupTwo,
        @"symlink": symlinkGroup, @"directory": directoryGroup,
        @"invalid": @42, @"remote": [NSURL URLWithString:@"https://example.com"]};
    measured = NO;
    [TGExtraTemporaryFiles usageWithCompletion:^(NSUInteger count, unsigned long long bytes, NSError *error) {
        NSCAssert(!error && count == 11 && bytes == 43, @"Include exact legacy log sizes, deduplicate groups and exclude foreign logs, symlink directories and folders named like logs");
        measured = YES;
    }];
    waitFor(^BOOL { return measured; });
    for (NSUInteger mode = 0; mode < 3; mode++) {
        testProxyAvailable = mode != 0;
        testProxyThrows = mode == 1;
        id savedContainers = testGroupContainers;
        if (mode == 2) testGroupContainers = @42;
        measured = NO;
        [TGExtraTemporaryFiles usageWithCompletion:^(NSUInteger count, unsigned long long bytes, NSError *error) {
            NSCAssert(!error && count == 9 && bytes == 34, @"Missing, throwing or incompatible Launch Services still allows Documents cleanup");
            measured = YES;
        }];
        waitFor(^BOOL { return measured; });
        testGroupContainers = savedContainers;
    }
    testProxyAvailable = YES;
    testProxyThrows = NO;
    NSURL *link = [temp URLByAppendingPathComponent:@"TGExtraVideoToVoice/external"];
    NSCAssert([manager createSymbolicLinkAtURL:link withDestinationURL:history.URLByDeletingLastPathComponent error:NULL], @"Prepare an external directory link");
    measured = NO;
    [TGExtraTemporaryFiles usageWithCompletion:^(NSUInteger count, unsigned long long bytes, NSError *error) {
        NSCAssert(!error && count == 12, @"Count the link itself without traversing external directories");
        measured = YES;
    }];
    waitFor(^BOOL { return measured; });
    __block BOOL cleared = NO;
    [TGExtraTemporaryFiles clearWithCompletion:^(NSError *error) {
        NSCAssert(!error && NSThread.isMainThread, @"Forced cleanup returns on the main queue");
        cleared = YES;
    }];
    waitFor(^BOOL { return cleared; });
    for (NSString *directory in uploadDirectories()) NSCAssert(!exists([temp URLByAppendingPathComponent:directory]), @"Remove upload sources on explicit force cleanup");
    NSCAssert(exists(unrelated) && exists(similar) && exists(preferences) && exists(history) && exists(journal), @"Keep other caches, saved history, settings and retry journals");
    NSCAssert(!exists(oldDocumentLog) && !exists(oldDebugLog) && !exists(groupLogOne) && !exists(groupLogTwo), @"Remove obsolete TGExtra logs in Documents and every app group");
    NSCAssert(!exists(groupLogTwo.URLByDeletingLastPathComponent) && exists(groupTwo), @"Remove an empty legacy log directory but keep the shared container");
    NSCAssert(exists(otherLog) && exists(telegramCache) && exists(documentsFile) && exists(directoryFile) &&
        exists(currentLog) && exists(wal), @"Keep other apps' logs, Telegram cache, unrelated documents, current diagnostics and SQLite sidecars");
    measured = NO;
    [TGExtraTemporaryFiles usageWithCompletion:^(NSUInteger count, unsigned long long bytes, NSError *error) {
        NSCAssert(!error && count == 0 && bytes == 0, @"Forced cleanup removes exactly the measured files");
        measured = YES;
    }];
    waitFor(^BOOL { return measured; });
    [manager removeItemAtURL:base error:NULL];
    puts("PASS temporary files: real copy hooks, failed copies, restart safety, exact count/size and forced cleanup");
} return 0; }
'''

with tempfile.TemporaryDirectory(prefix='tgextra-temporary-files-') as directory:
    directory = Path(directory)
    hook = directory / 'hooks.mm'
    if logos.exists():
        with hook.open('w') as output:
            subprocess.run(['perl', str(logos), '-c', 'generator=internal',
                            str(root / 'Sources/tgapi/TemporaryFileHooks.xm')], stdout=output, check=True)
    else:
        # CI's checks job has no Theos. Install the same production hook bodies
        # with Objective-C runtime calls, as Logos's internal generator does.
        hooks = (root / 'Sources/tgapi/TemporaryFileHooks.xm').read_text().split('%end')[0]
        hooks = hooks.replace('%hook NSFileManager', r'''
#import <objc/runtime.h>
static BOOL (*originalURL)(id, SEL, NSURL *, NSURL *, NSError **);
static BOOL (*originalPath)(id, SEL, NSString *, NSString *, NSError **);
''')
        hooks = hooks.replace('- (BOOL)copyItemAtURL:(NSURL *)source toURL:(NSURL *)destination error:(NSError **)error {',
                              'static BOOL copyURL(id self, SEL _cmd, NSURL *source, NSURL *destination, NSError **error) {')
        hooks = hooks.replace('- (BOOL)copyItemAtPath:(NSString *)source toPath:(NSString *)destination error:(NSError **)error {',
                              'static BOOL copyPath(id self, SEL _cmd, NSString *source, NSString *destination, NSError **error) {')
        hooks = hooks.replace('%orig', 'originalURL(self, _cmd, source, destination, error)', 1)
        hooks = hooks.replace('%orig', 'originalPath(self, _cmd, source, destination, error)', 1)
        hooks += r'''
__attribute__((constructor)) static void installCopyHooks(void) {
    Method url = class_getInstanceMethod(NSFileManager.class, @selector(copyItemAtURL:toURL:error:));
    Method path = class_getInstanceMethod(NSFileManager.class, @selector(copyItemAtPath:toPath:error:));
    originalURL = (BOOL (*)(id, SEL, NSURL *, NSURL *, NSError **))method_setImplementation(url, (IMP)copyURL);
    originalPath = (BOOL (*)(id, SEL, NSString *, NSString *, NSError **))method_setImplementation(path, (IMP)copyPath);
}
'''
        hook.write_text(hooks)
    test = directory / 'main.m'
    test.write_text(support)
    binary = directory / 'tests'
    subprocess.run(['clang', '-fobjc-arc', '-Werror', '-DTGEXTRA_TESTING',
                    '-I', str(root / 'Sources/tgapi'), '-framework', 'Foundation',
                    str(test), str(hook), '-lc++', '-o', str(binary)], check=True)
    subprocess.run([str(binary)], check=True, timeout=20)
