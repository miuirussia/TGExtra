#!/usr/bin/env python3
"""Check the production localization hook and scheduler without a UIKit window."""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parent.parent
source = (root / 'Sources/tgapi/UI/SettingsEntryHooks.xm').read_text()
helpers = source[source.index('static BOOL tgextraLabelMatchesLocalizedKey'):source.index('BOOL TGExtraIsTelegramSupportLabel')]
helpers += source[source.index('static BOOL tgextraLabelIsSupportRow'):source.index('static void tgextraDiagSettingsRow')]
scheduler = source[source.index('static void tryAttachTGExtraGesture(void);'):source.index('%hook TGLocalization')]
getter = source[source.index('- (id)get:(id)key {'):source.index('- (id)initWithVersion:')].replace('return %orig;', 'return @"Unrelated translation";')
support = r'''
#import <Foundation/Foundation.h>
#import <CoreFoundation/CoreFoundation.h>
@interface TGLocalization : NSObject
- (id)get:(id)key;
@end
@interface TGExtraGestureTarget : NSObject @end
@implementation TGExtraGestureTarget @end
static TGLocalization *TGLocalizationShared;
static BOOL _tgextraGestureAttached;
static NSUInteger scans;
static TGLocalization *getActiveTGLocalization(void) { return TGLocalizationShared; }
'''
tests = r'''
static void tryAttachTGExtraGesture(void) {
    if (_tgextraGestureAttached) return;
    scans++;
    NSCAssert(!tgextraLabelIsSupportRow(@"Chats"), @"Visit an ordinary accessibility label");
}
static void drain(void) { CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.03, false); }
int main(void) { @autoreleasepool {
    TGLocalizationShared = [TGLocalization new];
    for (NSUInteger i = 0; i < 100; i++) [TGLocalizationShared get:@"Settings.Title"];
    drain();
    NSCAssert(scans == 1, @"Coalesce lookups; localization inside the scan cannot schedule another scan");
    drain();
    NSCAssert(scans == 1, @"An unsuccessful search must become idle");
    [TGLocalizationShared get:@"DialogList.Title"];
    drain();
    NSCAssert(scans == 1, @"Unrelated screens do not trigger window scans");
    [TGLocalizationShared get:@"Settings.Title"];
    drain();
    NSCAssert(scans == 2, @"A later settings screen can retry");
    _tgextraGestureAttached = YES;
    [TGLocalizationShared get:@"Settings.Title"];
    drain();
    NSCAssert(scans == 2, @"Stop after attaching the gesture");
    puts("PASS settings search: coalescing, reentry, idle queue and screen-scoped retries");
} }
'''
with tempfile.TemporaryDirectory(prefix='tgextra-settings-search-') as tmp:
    path = Path(tmp)
    (path / 'main.m').write_text(support + helpers + scheduler + '@implementation TGLocalization\n' + getter + '@end\n' + tests)
    subprocess.run(['clang', '-fobjc-arc', '-Werror', '-framework', 'Foundation', '-framework', 'CoreFoundation',
                    str(path / 'main.m'), '-o', str(path / 'test')], check=True)
    subprocess.run([str(path / 'test')], check=True, timeout=10)
