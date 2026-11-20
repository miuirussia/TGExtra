#!/usr/bin/env python3
"""Check optional copy-protection getters against native and Swift-only layouts."""
from pathlib import Path
import os
import re
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
LOGOS = Path(os.environ.get('LOGOS_PL', ROOT / '.build/theos/bin/logos.pl'))
SOURCE = ROOT / 'Sources/tgapi/UI/CopyProtectionHooks.x'

HOST = r'''
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import "Compatibility.h"
#import "Constants.h"
@interface NSObject (TestCopyProtection)
- (BOOL)copyProtectionEnabled;
@end
static BOOL originalProtection(id self, SEL command) { return YES; }
static int incompatibleProtection(id self, SEL command) { return 7; }
static Class makeState(const char *name, BOOL getter, BOOL incompatible) {
    Class cls = objc_allocateClassPair(NSObject.class, name, 0);
    if (getter) {
        NSString *types = [NSString stringWithFormat:@"%s@:", incompatible ? @encode(int) : @encode(BOOL)];
        class_addMethod(cls, @selector(copyProtectionEnabled),
            incompatible ? (IMP)incompatibleProtection : (IMP)originalProtection, types.UTF8String);
    } else {
        class_addIvar(cls, "copyProtectionEnabled", sizeof(BOOL), 0, @encode(BOOL));
    }
    objc_registerClassPair(cls);
    return cls;
}
int main(int argc, const char **argv) {
    @autoreleasepool {
        NSString *mode = @(argv[1]);
        BOOL bad = [mode isEqual:@"incompatible"];
        BOOL swiftOnly = [mode isEqual:@"swift-only"];
        NSMutableArray *states = [NSMutableArray new];
        if ([mode isEqual:@"legacy"] || [mode isEqual:@"both"]) {
            [states addObject:makeState("_TtC10TelegramUI30ChatPresentationInterfaceState", YES, NO)];
        }
        if (![mode isEqual:@"missing"] && ![mode isEqual:@"legacy"]) {
            [states addObject:makeState("_TtC30ChatPresentationInterfaceState30ChatPresentationInterfaceState", !swiftOnly, bad)];
        }
        NSString *domain = [@"TGExtraCopyHook-" stringByAppendingString:NSUUID.UUID.UUIDString];
        NSUserDefaults *defaults = [[NSUserDefaults alloc] initWithSuiteName:domain];
        Method standard = class_getClassMethod(NSUserDefaults.class, @selector(standardUserDefaults));
        IMP previous = method_setImplementation(standard, imp_implementationWithBlock(^id(id cls) { return defaults; }));
        INSTALL_TEST_HOOKS
        NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:3];
        while (!TGExtraHookStatuses()[@"Copy protection UI"] && deadline.timeIntervalSinceNow > 0) {
            [NSRunLoop.currentRunLoop runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
        }
        NSString *expected = bad ? @"unavailable: getter ABI" : swiftOnly
            ? @"protocol policies; no Objective-C getter (optional)" : [mode isEqual:@"missing"]
            ? @"unavailable: presentation state" : @"installed";
        NSCAssert([TGExtraHookStatuses()[@"Copy protection UI"] isEqual:expected], @"Report the actual getter compatibility");
        for (Class cls in states) {
            Method getter = class_getInstanceMethod(cls, @selector(copyProtectionEnabled));
            if (swiftOnly) {
                NSCAssert(getter == NULL, @"Do not invent an Objective-C getter for Swift storage");
            } else if (bad) {
                NSCAssert(method_getImplementation(getter) == (IMP)incompatibleProtection,
                          @"Leave an incompatible getter untouched");
            } else {
                id state = [cls new];
                for (NSNumber *enabled in @[@NO, @YES, @NO]) {
                    [defaults setBool:enabled.boolValue forKey:kDisableForwardRestriction];
                    NSCAssert([state copyProtectionEnabled] == !enabled.boolValue,
                              @"Preserve original protection when disabled and bypass it when enabled");
                }
            }
        }
        [defaults removePersistentDomainForName:domain];
        method_setImplementation(standard, previous);
        printf("PASS optional copy hook: %s, ABI gating, status and preference isolation\n", argv[1]);
    }
}
'''

with tempfile.TemporaryDirectory(prefix='tgextra-copy-hooks-') as directory:
    work = Path(directory)
    hook = work / 'hook.m'
    if LOGOS.exists():
        hook.write_bytes(subprocess.check_output([
            'perl', str(LOGOS), '-c', 'generator=internal', str(SOURCE),
        ]))
        host = HOST.replace('INSTALL_TEST_HOOKS', '')
    else:
        # The checks job has no Theos. Keep the production getter bodies and
        # constructor guards, replacing only the Logos registration machinery.
        source = SOURCE.read_text()
        for group, alias in [('TGExtraCopyProtectionUI', 'UI'), ('TGExtraCopyProtectionState', 'State')]:
            source = re.sub(r'%group ' + group + r'\n%hook \w+\n',
                            f'static BOOL (*original{alias})(id, SEL);\n', source, count=1)
            source = source.replace('- (BOOL)copyProtectionEnabled {',
                                    f'static BOOL getter{alias}(id self, SEL _cmd) {{', 1)
            source = source.replace('return %orig;', f'return original{alias}(self, _cmd);', 1)
            variable = 'ui' if alias == 'UI' else 'state'
            source = re.sub(r'%init\(' + group + r', [^;]+\);',
                            f'original{alias} = (BOOL (*)(id, SEL))method_setImplementation({variable}Getter, (IMP)getter{alias});',
                            source, count=1)
        source = source.replace('%end', '').replace('%ctor', 'static void installTestHooks(void)')
        hook.write_text(source)
        host = HOST.replace('INSTALL_TEST_HOOKS', 'installTestHooks();')
    harness = work / 'main.m'
    harness.write_text('#include "hook.m"\n' + host)
    binary = work / 'tests'
    subprocess.run(['clang', '-fobjc-arc', '-Werror', '-framework', 'Foundation',
                    '-I' + str(ROOT / 'Sources/tgapi'), '-I' + str(ROOT / 'Sources/tgapi/UI'),
                    str(harness), '-o', str(binary)], check=True)
    for mode in ['legacy', 'state', 'both', 'swift-only', 'incompatible', 'missing']:
        subprocess.run([str(binary), mode], check=True, timeout=10)
