#!/usr/bin/env python3
"""Run production Logos hooks against real UIKit via Mac Catalyst on macOS."""
import os
from pathlib import Path
import platform
import subprocess
import tempfile

root = Path(__file__).resolve().parent.parent
environment = dict(os.environ)
xcode = Path('/Applications/Xcode.app/Contents/Developer')
if 'DEVELOPER_DIR' not in environment and xcode.exists():
    environment['DEVELOPER_DIR'] = str(xcode)
logos = Path(environment.get('LOGOS_PL', root / '.build/theos/bin/logos.pl'))
if platform.system() != 'Darwin' or platform.machine() != 'arm64' or not logos.exists():
    print('SKIP real UIKit capture test: requires Apple Silicon, Xcode and Logos')
    raise SystemExit(0)
sdk = Path(subprocess.check_output(['xcrun', '--sdk', 'macosx', '--show-sdk-path'],
                                  env=environment, text=True).strip())
frameworks = sdk / 'System/iOSSupport/System/Library/Frameworks'
if not (frameworks / 'UIKit.framework/Headers/UIKit.h').exists():
    print('SKIP real UIKit capture test: Mac Catalyst SDK unavailable')
    raise SystemExit(0)
with tempfile.TemporaryDirectory(prefix='tgextra-uikit-capture-') as directory:
    work = Path(directory)
    hook = work / 'capture.mm'
    hook.write_bytes(subprocess.check_output([
        'perl', str(logos), '-c', 'generator=internal', str(root / 'Sources/tgapi/PaidMediaCapture.xm'),
    ]))
    binary = work / 'tests'
    subprocess.run([
        'xcrun', 'clang++', '-target', 'arm64-apple-ios17.0-macabi', '-isysroot', str(sdk),
        '-iframework', str(frameworks), '-F', str(frameworks), '-fobjc-arc', '-Werror',
        '-Wno-deprecated-declarations', '-I', str(root / 'Sources/tgapi'),
        '-framework', 'UIKit', '-framework', 'Foundation', '-framework', 'AVFoundation',
        '-framework', 'QuartzCore', '-Wl,-rpath,/System/iOSSupport/System/Library/Frameworks',
        str(hook), str(root / 'Tests/paid_media_uikit.mm'), '-o', str(binary),
    ], env=environment, check=True)
    subprocess.run([str(binary)], check=True, timeout=30)
