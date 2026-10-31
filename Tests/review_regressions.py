#!/usr/bin/env python3
"""Exercise picker relocation, coordinate validation and the production settings row model."""
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parent.parent
picker = (ROOT / 'Sources/tgapi/FilePickerFix.xm').read_text()
helper = picker[picker.index('static NSURL *TGExtraRelocatePickedFile'):picker.index('%hook LegacyMediaPickerUIICloudFileController')]
methods = picker[picker.index('- (void)documentPicker:'):picker.index('%hook NSURL')]
methods = methods[:methods.index('%end')]
single, multiple = methods.split('- (void)documentPicker:(id)picker didPickDocumentsAtURLs:', 1)
single = single.replace('%orig;', 'self.captured = url ? @[url] : @[];').replace('%orig(picker, TGExtraRelocatePickedFile(url));', 'self.captured = @[TGExtraRelocatePickedFile(url)];')
multiple = '- (void)documentPicker:(id)picker didPickDocumentsAtURLs:' + multiple
multiple = multiple.replace('%orig;', 'self.captured = urls;').replace('%orig(picker, relocated);', 'self.captured = relocated;')
# The copied class list owns its count; registering another class cannot grow that buffer.
scan = picker[picker.index('unsigned int numClasses = 0;'):picker.index('\n\t\tClass DocumentPickerViewController')]
assert 'objc_copyClassList' in scan and 'objc_getClassList' not in picker

support = r'''
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import "Location.h"
#import "SettingsRows.h"
#define customLog2(...) do {} while (0)
static BOOL enabled = YES;
static BOOL shouldFixFilePicker(void) { return enabled; }
@interface Picker : NSObject
@property NSArray<NSURL *> *captured;
@end
'''

tests = r'''
@end
@interface CoordinateDefaults : NSUserDefaults
@property NSMutableDictionary *values;
@end
@implementation CoordinateDefaults
- (instancetype)init { if ((self = [super init])) _values = [NSMutableDictionary new]; return self; }
- (id)objectForKey:(NSString *)key { return self.values[key]; }
@end
int main(void) { @autoreleasepool {
    NSFileManager *fm = NSFileManager.defaultManager;
    NSURL *base = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString]];
    NSMutableArray *urls = [NSMutableArray new];
    for (NSString *part in @[@"one", @"two"]) {
        NSURL *directory = [base URLByAppendingPathComponent:part];
        [fm createDirectoryAtURL:directory withIntermediateDirectories:YES attributes:nil error:NULL];
        NSURL *url = [directory URLByAppendingPathComponent:@"same.txt"];
        [part writeToURL:url atomically:YES encoding:NSUTF8StringEncoding error:NULL];
        [urls addObject:url];
    }
    Picker *picker = [Picker new];
    enabled = NO;
    [picker documentPicker:nil didPickDocumentsAtURLs:urls];
    NSCAssert([picker.captured isEqual:urls], @"Disabled hooks preserve original URLs");
    enabled = YES;
    [picker documentPicker:nil didPickDocumentsAtURLs:urls];
    NSCAssert(picker.captured.count == 2 && [NSSet setWithArray:picker.captured].count == 2, @"Same names need distinct URLs");
    NSArray *expected = @[@"one", @"two"];
    for (NSUInteger i = 0; i < 2; i++) {
        NSURL *url = picker.captured[i];
        NSCAssert([url.lastPathComponent isEqual:@"same.txt"], @"Keep the original file name");
        NSCAssert([[NSString stringWithContentsOfURL:url encoding:NSUTF8StringEncoding error:NULL] isEqual:expected[i]], @"Keep each file's content");
        [fm removeItemAtURL:url.URLByDeletingLastPathComponent error:NULL];
    }
    NSURL *missing = [base URLByAppendingPathComponent:@"missing.txt"];
    [picker documentPicker:nil didPickDocumentAtURL:missing];
    NSCAssert([picker.captured.firstObject isEqual:missing], @"A failed move falls back to the original URL");
    [picker documentPicker:nil didPickDocumentsAtURLs:@[missing]];
    NSCAssert([picker.captured.firstObject isEqual:missing], @"Batch failure never substitutes a nonexistent destination");
    NSURL *single = [base URLByAppendingPathComponent:@"single.txt"];
    [@"single" writeToURL:single atomically:YES encoding:NSUTF8StringEncoding error:NULL];
    [picker documentPicker:nil didPickDocumentAtURL:single];
    NSCAssert([[NSString stringWithContentsOfURL:picker.captured.firstObject encoding:NSUTF8StringEncoding error:NULL] isEqual:@"single"], @"Single-file relocation");
    [fm removeItemAtURL:[picker.captured.firstObject URLByDeletingLastPathComponent] error:NULL];
    [fm removeItemAtURL:base error:NULL];

    CoordinateDefaults *defaults = [CoordinateDefaults new];
    CLLocationCoordinate2D coordinate;
    NSCAssert(!TGExtraSavedCoordinate(defaults, &coordinate), @"Missing coordinates are not (0, 0)");
    for (NSArray *pair in @[@[@0, @0], @[@0, @50], @[@50, @0], @[@90, @180], @[@-90, @-180], @[@12.345678901, @34.567890123]]) {
        defaults.values[FAKE_LATITUDE_KEY] = pair[0];
        defaults.values[FAKE_LONGITUDE_KEY] = pair[1];
        NSCAssert(TGExtraSavedCoordinate(defaults, &coordinate), @"Accept valid coordinates including zero");
        NSCAssert(coordinate.latitude == [pair[0] doubleValue] && coordinate.longitude == [pair[1] doubleValue], @"Keep double precision");
    }
    for (id latitude in @[@91, @-91, @(NAN), @"bad"]) {
        defaults.values[FAKE_LATITUDE_KEY] = latitude;
        NSCAssert(!TGExtraSavedCoordinate(defaults, &coordinate), @"Reject invalid stored coordinates");
    }
    defaults.values[FAKE_LATITUDE_KEY] = @0;
    defaults.values[FAKE_LONGITUDE_KEY] = @181;
    NSCAssert(!TGExtraSavedCoordinate(defaults, &coordinate), @"Reject invalid longitude");
    [defaults.values removeObjectForKey:FAKE_LONGITUDE_KEY];
    NSCAssert(!TGExtraSavedCoordinate(defaults, &coordinate), @"Require both components");

    NSArray *ghostKeys = @[kDisableOnlineStatus, kDisableTypingStatus, kDisableRecordingVideoStatus,
        kDisableUploadingVideoStatus, kDisableRecordingVoiceStatus, kDisableUploadingVoiceStatus,
        kDisableUploadingPhotoStatus, kDisableUploadingFileStatus, kDisableChoosingLocationStatus,
        kDisableChoosingContactStatus, kDisablePlayingGameStatus, kDisableRecordingRoundVideoStatus,
        kDisableUploadingRoundVideoStatus, kDisableSpeakingInGroupCallStatus, kDisableChoosingStickerStatus,
        kDisableEmojiInteractionStatus, kDisableEmojiAcknowledgementStatus, kDisableMessageReadReceipt,
        kDisableReactionReadReceipt, kDisableMentionReadReceipt, kDisableStoriesReadReceipt];
    NSCAssert([[TGExtraSettingRow.ghostRows valueForKey:@"key"] isEqual:ghostKeys], @"Keep every Ghost toggle in order");
    NSDictionary *sections = @{@(MESSAGE_HISTORY): @[kAntiRevoke, kAntiAutoDelete, kAntiEdit],
        @(CONTENT_ACCESS): @[kDisableForwardRestriction, kIgnorePrivateChatCopyProtection, kDisableScreenshotNotification, kAntiSelfDestruct, kHideDisappearingLabel],
        @(MEDIA): @[kVideoToVoice, kVideoToRound, kForceTLottie, FILE_PICKER_FIX_KEY], @(INTERFACE): @[kDisableAllAds, kDisableDoubleTapReactions, kHideRecordingButton]};
    for (NSNumber *section in sections) {
        NSArray *rows = [TGExtraSettingRow featureRowsForSection:section.integerValue];
        NSCAssert([[rows valueForKey:@"key"] isEqual:sections[section]], @"Keep all categorized toggles");
        for (NSUInteger i = 0; i < rows.count; i++) {
            TGExtraSettingRow *row = [TGExtraSettingRow rowForSection:section.integerValue row:i];
            NSCAssert(row == rows[i] && row.titleKey.length && row.subtitleKey.length && row.icon.length, @"Identity and presentation use the same row");
        }
        NSCAssert(![TGExtraSettingRow rowForSection:section.integerValue row:rows.count], @"Reject out-of-range rows");
    }
    for (NSUInteger i = 0; i < ghostKeys.count; i++) {
        NSCAssert([[TGExtraSettingRow rowForSection:GHOST_MODE row:i + 2].key isEqual:ghostKeys[i]], @"Expanded Ghost mapping");
    }
    for (NSNumber *section in @[@(GHOST_MODE), @(FAKE_LOCATION)]) {
        NSCAssert(![TGExtraSettingRow rowForSection:section.integerValue row:1], @"Action rows must not write a switch preference");
    }
    NSCAssert(![TGExtraSettingRow rowForSection:LANGUAGE row:0], @"Language is an action");
    puts("PASS picker filename collisions, failures, disabled hooks; zero/invalid coordinates; settings row coverage and identity");
} return 0; }
'''

with tempfile.TemporaryDirectory(prefix='tgextra-regressions-') as tmp:
    path = Path(tmp)
    class_test = '''
static void testClassSnapshot(void) {
''' + scan.replace('if (!classes) return;', 'NSCAssert(classes, @"Class snapshot exists");') + r'''
    Class extra = objc_allocateClassPair(NSObject.class, "TGExtraSnapshotLateClass", 0);
    objc_registerClassPair(extra);
    for (unsigned int i = 0; i < numClasses; i++) NSCAssert(classes[i] != extra, @"Registration cannot change an existing snapshot");
    free(classes);
}
'''
    # Keep the production snapshot allocation in the test, then register a late class.
    tests = tests.replace('    NSFileManager *fm', '    testClassSnapshot();\n    NSFileManager *fm', 1)
    harness = path / 'regressions.m'
    harness.write_text(support + helper + class_test + '@implementation Picker\n' + single + multiple + tests)
    binary = path / 'regressions'
    subprocess.run(['clang', '-fobjc-arc', '-Werror', '-framework', 'Foundation', '-framework', 'CoreLocation',
                    '-I' + str(ROOT / 'Sources/tgapi'), '-I' + str(ROOT / 'Sources/tgapi/UI'),
                    str(harness), str(ROOT / 'Sources/tgapi/UI/SettingsRows.m'), '-o', str(binary)], check=True)
    subprocess.run([str(binary)], check=True)
