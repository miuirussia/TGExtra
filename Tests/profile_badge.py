#!/usr/bin/env python3
"""Exercise the real profile layout hook against Mac Catalyst UIKit."""
import os
from pathlib import Path
import platform
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parent.parent
environment = dict(os.environ)
xcode = Path('/Applications/Xcode.app/Contents/Developer')
if 'DEVELOPER_DIR' not in environment and xcode.exists():
    environment['DEVELOPER_DIR'] = str(xcode)
logos = Path(environment.get('LOGOS_PL', ROOT / '.build/theos/bin/logos.pl'))
if platform.system() != 'Darwin' or not logos.exists():
    print('SKIP profile badge UIKit tests: requires macOS and Logos')
    raise SystemExit(0)
sdk = Path(subprocess.check_output(['xcrun', '--sdk', 'macosx', '--show-sdk-path'],
                                  env=environment, text=True).strip())
frameworks = sdk / 'System/iOSSupport/System/Library/Frameworks'
if not (frameworks / 'UIKit.framework/Headers/UIKit.h').exists():
    print('SKIP profile badge UIKit tests: Mac Catalyst SDK unavailable')
    raise SystemExit(0)
with tempfile.TemporaryDirectory(prefix='tgextra-profile-badge-') as directory:
    work = Path(directory)
    hook = work / 'profile.m'
    hook.write_bytes(subprocess.check_output([
        'perl', str(logos), '-c', 'generator=internal',
        str(ROOT / 'Sources/tgapi/UI/ProfileHooks.x'),
    ]))
    binary = work / 'tests'
    subprocess.run([
        'xcrun', 'clang', '-target', f'{platform.machine()}-apple-ios17.0-macabi', '-isysroot', str(sdk),
        '-iframework', str(frameworks), '-F', str(frameworks), '-fobjc-arc', '-Werror',
        '-I', str(ROOT / 'Sources/tgapi/UI'), '-framework', 'UIKit', '-framework', 'Foundation',
        '-framework', 'QuartzCore', '-framework', 'CoreGraphics',
        '-Wl,-rpath,/System/iOSSupport/System/Library/Frameworks',
        str(hook), str(ROOT / 'Tests/profile_badge_uikit.m'), '-o', str(binary),
    ], env=environment, check=True)
    subprocess.run([str(binary)], check=True, timeout=30)
