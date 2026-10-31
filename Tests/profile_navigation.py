#!/usr/bin/env python3
"""Exercise native profile lookup with separately compiled host Swift modules."""
from pathlib import Path
import os
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parent.parent
with tempfile.TemporaryDirectory(prefix='tgextra-profile-navigation-') as directory:
    tmp = Path(directory)
    environment = dict(os.environ, TGEXTRA_TEST_LOG_PATH=str(tmp / 'profile.log'))

    def run(*args):
        subprocess.run(args, check=True, cwd=ROOT, env=environment)

    for module, source, dependencies in [
        ('SwiftSignalKit', 'Tests/Fixtures/MessageCleanup/Signal.swift', []),
        ('Postbox', 'Tests/Fixtures/ProfileNavigation/Postbox.swift', ['-lSwiftSignalKit']),
        ('TelegramCore', 'Tests/Fixtures/ProfileNavigation/TelegramCore.swift', ['-lPostbox']),
    ]:
        run('swiftc', '-emit-library', '-emit-module', '-module-name', module,
            '-I', str(tmp), '-L', str(tmp), *dependencies, source,
            '-emit-module-path', str(tmp / f'{module}.swiftmodule'),
            '-o', str(tmp / f'lib{module}.dylib'))
    bridge = tmp / 'navigation.o'
    run('clang', '-fobjc-arc', '-Werror', '-c', 'Sources/tgapiC/ProfileNavigation.m', '-o', str(bridge))
    logger = tmp / 'logger.o'
    run('clang', '-fobjc-arc', '-Werror', '-DTGEXTRA_TESTING', '-c',
        'Sources/tgapi/Logger/Logger.m', '-o', str(logger))
    missing = tmp / 'missing.m'
    missing.write_text('''#import "Tweak.h"
void TGExtraProfileLookupBody(void *context, void *transaction) {}
int main(void) {
    NSCAssert(!TGExtraProfileLookupAvailable(), @"Missing host exports must disable the native bridge");
    puts("PASS missing native profile exports are handled safely");
}
''')
    run('clang', '-fobjc-arc', '-Werror', '-framework', 'Foundation',
        '-I', 'Sources/tgapiC/include', str(missing), str(bridge), str(logger), '-o', str(tmp / 'missing'))
    run(str(tmp / 'missing'))
    binary = tmp / 'navigation'
    main = tmp / 'main.swift'
    main.write_text((ROOT / 'Tests/profile_navigation.swift').read_text())
    for optimization in ['-Onone', '-O']:
        run('swiftc', optimization, '-I', str(tmp), '-L', str(tmp),
            '-lPostbox', '-lSwiftSignalKit', '-lTelegramCore', '-I', 'Sources/tgapiC/include',
            '-import-objc-header', 'Sources/tgapi/Logger/Logger.h',
            '-Xlinker', '-rpath', '-Xlinker', str(tmp),
            'Sources/tgapi/HostValueReader.swift', 'Sources/tgapi/UI/ProfileNavigation.swift',
            str(main), str(bridge), str(logger), '-o', str(binary), '-emit-executable')
        run(str(binary))
    definitions = (ROOT / 'Tests/profile_navigation.swift').read_text().split(
        'precondition(TGExtraProfileLookupAvailable()')[0]
    main.write_text(definitions + '''
let postbox = Postbox()
private let node = ProfileNode(postbox) { _, _ in preconditionFailure("Unsupported future layout") }
var completed = false
TGExtraClearLog()
ProfileNavigation.loadProfile(peerId: 42, fromNode: node) { action in
    precondition(action == nil)
    completed = true
}
precondition(completed && postbox.transactions == 0)
precondition(TGExtraReadLog().contains("peer=42 reason=unsupported native"))
print("PASS changed future native layout is rejected before calling the native ABI")
''')
    for future in ['FUTURE_PROFILE_LAYOUT', 'FUTURE_PEER_ID_LAYOUT']:
        for module, dependency in [('Postbox', 'SwiftSignalKit'), ('TelegramCore', 'Postbox')]:
            run('swiftc', '-D', future, '-emit-library', '-emit-module', '-module-name', module,
                '-I', str(tmp), '-L', str(tmp), f'-l{dependency}',
                f'Tests/Fixtures/ProfileNavigation/{module}.swift',
                '-emit-module-path', str(tmp / f'{module}.swiftmodule'), '-o', str(tmp / f'lib{module}.dylib'))
        run('swiftc', '-I', str(tmp), '-L', str(tmp), '-lPostbox', '-lSwiftSignalKit', '-lTelegramCore',
            '-import-objc-header', 'Sources/tgapi/Logger/Logger.h',
            '-I', 'Sources/tgapiC/include', '-Xlinker', '-rpath', '-Xlinker', str(tmp),
            'Sources/tgapi/HostValueReader.swift', 'Sources/tgapi/UI/ProfileNavigation.swift',
            str(main), str(bridge), str(logger), '-o', str(binary))
        run(str(binary))
