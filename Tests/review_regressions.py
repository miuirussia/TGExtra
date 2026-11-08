#!/usr/bin/env python3
"""Exercise picker relocation, coordinate validation and the production settings row model."""
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parent.parent
picker = (ROOT / 'Sources/tgapi/FilePickerFix.x').read_text()
helper = picker[picker.index('static NSURL *TGExtraRelocatePickedFile'):picker.index('%hook LegacyMediaPickerUIICloudFileController')]
methods = picker[picker.index('- (void)documentPicker:'):picker.index('%hook NSURL')]
methods = methods[:methods.index('%end')]
single, multiple = methods.split('- (void)documentPicker:(id)picker didPickDocumentsAtURLs:', 1)
single = single.replace('&%orig', 'testSingleOriginal').replace('%orig;', 'self.captured = url ? @[url] : @[];').replace('%orig(picker, TGExtraRelocatePickedFile(url));', 'self.captured = @[TGExtraRelocatePickedFile(url)];')
multiple = '- (void)documentPicker:(id)picker didPickDocumentsAtURLs:' + multiple
multiple = multiple.replace('&%orig', 'testMultipleOriginal').replace('%orig;', 'self.captured = urls;').replace('%orig(picker, relocated);', 'self.captured = relocated;')
# The copied class list owns its count; registering another class cannot grow that buffer.
scan = picker[picker.index('unsigned int numClasses = 0;'):picker.index('\n\t\tClass DocumentPickerViewController')]
assert 'objc_copyClassList' in scan and 'objc_getClassList' not in picker

support = r'''
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import "Location.h"
#import "SettingsRows.h"
#import "AudioFileVoicePrompt.h"
#define customLog(...) do {} while (0)
static BOOL enabled = YES;
static BOOL shouldFixFilePicker(void) { return enabled; }
@interface Picker : NSObject
@property NSArray<NSURL *> *captured;
@property NSUInteger cancellations;
- (void)documentPickerWasCancelled:(id)picker;
@end
static void testSingleOriginal(Picker *self, SEL command, id picker, NSURL *url) { self.captured = @[url]; }
static void testMultipleOriginal(Picker *self, SEL command, id picker, NSArray *urls) { self.captured = urls; }
static NSUInteger conversions, prompts, audioCount;
static void (^answerPrompt)(TGExtraAudioFileChoice);
static BOOL TGExtraIsAudioFile(NSURL *url) { return [@[@"wav", @"mp3"] containsObject:url.pathExtension.lowercaseString]; }
static NSURL *TGExtraConvertAudioFile(NSURL *url) {
    if (!TGExtraIsAudioFile(url)) return url;
    conversions++;
    return [url URLByAppendingPathExtension:@"voice"];
}
void TGExtraConfirmAudioFileConversion(UIViewController *picker, NSUInteger count, void (^completion)(TGExtraAudioFileChoice)) {
    prompts++; audioCount = count; answerPrompt = [completion copy];
}
static void awaitPicker(Picker *picker) {
    NSDate *until = [NSDate dateWithTimeIntervalSinceNow:2];
    while (!picker.captured && until.timeIntervalSinceNow > 0) [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
    NSCAssert(picker.captured, @"Picker completion reaches the UI thread");
}
static void TGExtraShowToast(NSString *text) {}
@interface TGExtraLocalization : NSObject
+ (NSString *)localizedStringForKey:(NSString *)key;
@end
@implementation TGExtraLocalization
+ (NSString *)localizedStringForKey:(NSString *)key { return key; }
@end
@interface TLParser : NSObject
+ (BOOL)audioFileVoiceChatSupported;
@end
static BOOL supportedChat = YES;
@implementation TLParser
+ (BOOL)audioFileVoiceChatSupported { return supportedChat; }
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
    enabled = NO;
    NSURL *audio = [base URLByAppendingPathComponent:@"audio.wav"];
    NSURL *document = [base URLByAppendingPathComponent:@"notes.pdf"];
    [NSUserDefaults.standardUserDefaults setBool:YES forKey:kAudioToVoice];
    picker.captured = nil;
    [picker documentPicker:nil didPickDocumentAtURL:audio];
    NSCAssert(prompts == 1 && audioCount == 1 && conversions == 0 && !picker.captured, @"Picking audio asks before conversion or sending");
    answerPrompt(TGExtraAudioFileChoiceOriginal); answerPrompt = nil;
    awaitPicker(picker);
    NSCAssert(conversions == 0 && [picker.captured isEqual:@[audio]], @"Choosing a file preserves the original audio");
    picker.captured = nil;
    [picker documentPicker:nil didPickDocumentsAtURLs:@[audio, document]];
    NSCAssert(prompts == 2 && audioCount == 1 && conversions == 0 && !picker.captured, @"Mixed selections show one prompt for audio only");
    answerPrompt(TGExtraAudioFileChoiceVoice); answerPrompt = nil;
    awaitPicker(picker);
    NSCAssert((conversions == 1 && [picker.captured isEqual:@[[audio URLByAppendingPathExtension:@"voice"], document]]), @"Only the confirmed audio becomes voice; other files stay unchanged");
    for (NSUInteger multiple = 0; multiple < 2; multiple++) {
        picker.captured = nil;
        if (multiple) [picker documentPicker:nil didPickDocumentsAtURLs:@[audio]];
        else [picker documentPicker:nil didPickDocumentAtURL:audio];
        answerPrompt(TGExtraAudioFileChoiceCancel); answerPrompt = nil;
        NSCAssert(!picker.captured && conversions == 1, @"Cancellation neither converts nor sends any files");
    }
    NSCAssert(picker.cancellations == 2, @"Cancellation closes the host's pending file selection");
    NSUInteger previousPrompts = prompts;
    [picker documentPicker:nil didPickDocumentsAtURLs:@[document]];
    awaitPicker(picker);
    NSCAssert(prompts == previousPrompts && conversions == 1, @"Other file types need no confirmation");
    [NSUserDefaults.standardUserDefaults setBool:NO forKey:kAudioToVoice];
    [picker documentPicker:nil didPickDocumentAtURL:audio];
    NSCAssert(prompts == previousPrompts && [picker.captured isEqual:@[audio]], @"The checkbox gates audio prompts");
    [NSUserDefaults.standardUserDefaults setBool:YES forKey:kAudioToVoice];
    supportedChat = NO;
    [picker documentPicker:nil didPickDocumentAtURL:audio];
    NSCAssert(prompts == previousPrompts && conversions == 1, @"Secret chats keep ordinary file sending");
    [NSUserDefaults.standardUserDefaults removeObjectForKey:kAudioToVoice];
    supportedChat = YES;
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
        kDisableReactionReadReceipt, kDisableMentionReadReceipt, kDisableStoriesReadReceipt, kGhostKeepVoiceUnread, kGhostReadOnReply];
    NSCAssert([[TGExtraSettingRow.ghostRows valueForKey:@"key"] isEqual:ghostKeys], @"Keep every Ghost toggle in order");
    NSDictionary *sections = @{@(MESSAGE_HISTORY): @[kAntiRevoke, kAntiAutoDelete, kAntiEdit, kSaveDeletedStories, kForwardDropAuthor],
        @(CONTENT_ACCESS): @[kDisableForwardRestriction, kIgnorePrivateChatCopyProtection, kDisableScreenshotNotification, kAntiSelfDestruct, kHideDisappearingLabel],
        @(MEDIA): @[kVideoToVoice, kAudioToVoice, kVideoToRound, kForceTLottie, FILE_PICKER_FIX_KEY], @(INTERFACE): @[kDisableAllAds, kDisableDoubleTapReactions, kHideRecordingButton]};
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
    puts("PASS picker confirmation before conversion/send, file/voice/cancel choices, checkbox gating, mixed files, relocation and settings rows");
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
    harness.write_text(support + helper + class_test + '@implementation Picker\n- (void)documentPickerWasCancelled:(id)picker { self.cancellations++; }\n' + single + multiple + tests)
    binary = path / 'regressions'
    subprocess.run(['clang', '-fobjc-arc', '-Werror', '-framework', 'Foundation', '-framework', 'CoreLocation',
                    '-I' + str(ROOT / 'Sources/tgapi'), '-I' + str(ROOT / 'Sources/tgapi/UI'),
                    str(harness), str(ROOT / 'Sources/tgapi/UI/SettingsRows.m'), '-o', str(binary)], check=True)
    subprocess.run([str(binary)], check=True)
