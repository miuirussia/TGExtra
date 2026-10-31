#!/usr/bin/env python3
"""Exercise the exported host Swift ABI and the production cleanup coordinator."""
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parent.parent
with tempfile.TemporaryDirectory(prefix='tgextra-cleanup-') as directory:
    tmp = Path(directory)
    def run(*args):
        subprocess.run(args, check=True, cwd=ROOT)
    run('swiftc', '-emit-library', '-emit-module', '-module-name', 'SwiftSignalKit',
        'Tests/Fixtures/MessageCleanup/Signal.swift', '-emit-module-path', str(tmp / 'SwiftSignalKit.swiftmodule'),
        '-o', str(tmp / 'libSwiftSignalKit.dylib'))
    run('swiftc', '-emit-library', '-emit-module', '-module-name', 'Postbox', '-I', str(tmp), '-L', str(tmp), '-lSwiftSignalKit',
        'Tests/Fixtures/MessageCleanup/Postbox.swift', '-emit-module-path', str(tmp / 'Postbox.swiftmodule'),
        '-o', str(tmp / 'libPostbox.dylib'))
    for name in ['MessageCleanup', 'HistoryAccount']:
        run('clang', '-fobjc-arc', '-Werror', '-c', f'Sources/tgapiC/{name}.m', '-o', str(tmp / f'{name}.o'))
    binary = tmp / 'cleanup-tests'
    for optimization in ['-Onone', '-O']:
        run('swiftc', optimization, '-I', str(tmp), '-L', str(tmp), '-lPostbox', '-lSwiftSignalKit',
            '-I', 'Sources/tgapiC/include', '-Xlinker', '-rpath', '-Xlinker', str(tmp),
            'Sources/tgapi/MessageDataCleanup.swift', 'Sources/tgapi/MessageKey.swift',
            'Sources/tgapi/HostValueReader.swift', 'Sources/tgapi/HostAccountReader.swift',
            'Tests/message_cleanup.swift', str(tmp / 'MessageCleanup.o'), str(tmp / 'HistoryAccount.o'), '-o', str(binary))
        run(str(binary))
