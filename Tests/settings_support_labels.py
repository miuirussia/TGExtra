#!/usr/bin/env python3
"""Run the actual settings-row label helpers with Foundation (macOS/GNUstep)."""
from pathlib import Path
import shlex
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parent.parent
source = (ROOT / 'Sources/tgapi/UI/UIHooks.xm').read_text()
helpers = source[source.index('BOOL TGExtraIsTelegramSupportLabel('):]
helpers = helpers[:helpers.index('// Is this accessibility label')]

support = r'''
#import <Foundation/Foundation.h>
static NSString *supportTranslation;
@interface TGLocalization : NSObject
- (NSString *)get:(NSString *)key;
@end
@implementation TGLocalization
- (NSString *)get:(NSString *)key { return supportTranslation ?: key; }
@end
static TGLocalization *localization;
static TGLocalization *getActiveTGLocalization(void) { return localization; }
'''

tests = r'''
int main(void) {
    @autoreleasepool {
        for (NSString *label in @[@"Ask a Question", @"Задать вопрос", @"提问", @"質問する"]) {
            NSCAssert(TGExtraIsTelegramSupportLabel(label), @"Offline fallback: %@", label);
        }
        for (NSString *label in @[@"", @"TGExtra", @"Send a Gift", @"Support", @"About Turrit", @"swiftgram", @"Ask a Question about my profile"]) {
            NSCAssert(!TGExtraIsTelegramSupportLabel(label), @"Not a Telegram settings support row: %@", label);
        }
        NSCAssert(!TGExtraIsTelegramSupportLabel(nil), @"Missing label");
        localization = [TGLocalization new];
        NSCAssert(!TGExtraIsTelegramSupportLabel(@"Settings.Support"), @"A missing translation returns its key");
        supportTranslation = @"طرح سؤال";
        NSCAssert(TGExtraIsTelegramSupportLabel(supportTranslation), @"Use the host's language");
        NSCAssert(!TGExtraIsTelegramSupportLabel(@"سؤال"), @"Do not accept part of a translated label");
        supportTranslation = @"Ställ en fråga";
        NSCAssert(TGExtraIsTelegramSupportLabel(@"STÄLL EN FRÅGA"), @"Changing host language");
        NSCAssert(!TGExtraIsTelegramSupportLabel(@"Ställ en fråga about my profile"), @"Do not accept extra profile text");
        puts("PASS settings support detection, fallback languages, host language changes and unrelated labels");
    }
    return 0;
}
'''

with tempfile.TemporaryDirectory(prefix='tgextra-settings-') as tmp:
    path = Path(tmp)
    harness = path / 'labels.m'
    harness.write_text(support + helpers + tests)
    binary = path / 'labels'
    if sys.platform == 'darwin':
        command = ['clang', '-fobjc-arc', '-Werror', '-framework', 'Foundation',
                   str(harness), '-o', str(binary)]
    else:
        flags = shlex.split(subprocess.check_output(['gnustep-config', '--objc-flags'], text=True))
        libs = shlex.split(subprocess.check_output(['gnustep-config', '--base-libs'], text=True))
        objc_include = subprocess.check_output(['gcc', '-print-file-name=include'], text=True).strip()
        command = ['clang', *flags, '-I' + objc_include, '-Werror', str(harness), '-o', str(binary), *libs]
    subprocess.run(command, check=True)
    subprocess.run([str(binary)], check=True)
