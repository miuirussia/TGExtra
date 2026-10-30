#!/usr/bin/env python3
"""Run review regressions against production UIKit and location code."""
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
sdk = Path(subprocess.check_output(['xcrun', '--sdk', 'macosx', '--show-sdk-path'], env=environment, text=True).strip())
frameworks = sdk / 'System/iOSSupport/System/Library/Frameworks'
if not (frameworks / 'UIKit.framework/Headers/UIKit.h').exists():
    print('SKIP review UIKit regressions: requires Mac Catalyst SDK')
    raise SystemExit(0)
with tempfile.TemporaryDirectory(prefix='tgextra-review-fixes-') as directory:
    binary = Path(directory) / 'tests'
    sources = ['Sources/tgapi/FakeLocationManager.m', 'Sources/tgapi/UI/SettingsCells.m',
               'Sources/tgapi/Logger/Logger.m', 'Tests/review_fixes.m']
    subprocess.run([
        'xcrun', 'clang', '-target', f'{platform.machine()}-apple-ios17.0-macabi', '-isysroot', str(sdk),
        '-iframework', str(frameworks), '-F', str(frameworks), '-fobjc-arc', '-Werror',
        '-Wno-deprecated-declarations', '-DTGEXTRA_TESTING', '-I', str(root / 'Sources/tgapi'),
        '-framework', 'UIKit', '-framework', 'Foundation', '-framework', 'CoreLocation',
        '-Wl,-rpath,/System/iOSSupport/System/Library/Frameworks',
        *(str(root / source) for source in sources), '-o', str(binary),
    ], env=environment, check=True)
    subprocess.run([str(binary)], check=True, timeout=30)
