#!/usr/bin/env python3
"""Exercise the production layout bridge with real UIKit and host-shaped Swift objects."""
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
if platform.system() != 'Darwin' or platform.machine() != 'arm64':
    print('SKIP UIKit recording layout test: requires Apple Silicon and Mac Catalyst')
    raise SystemExit(0)
sdk = Path(subprocess.check_output(['xcrun', '--sdk', 'macosx', '--show-sdk-path'],
                                  env=environment, text=True).strip())
frameworks = sdk / 'System/iOSSupport/System/Library/Frameworks'
if not (frameworks / 'UIKit.framework/Headers/UIKit.h').exists():
    print('SKIP UIKit recording layout test: Mac Catalyst SDK unavailable')
    raise SystemExit(0)
target = 'arm64-apple-ios17.0-macabi'
with tempfile.TemporaryDirectory(prefix='tgextra-recording-layout-') as directory:
    work = Path(directory)
    obj = work / 'layout.o'
    subprocess.run([
        'xcrun', 'clang', '-target', target, '-isysroot', str(sdk),
        '-iframework', str(frameworks), '-F', str(frameworks), '-fobjc-arc', '-Werror',
        '-I', str(ROOT / 'Sources/tgapi'), '-c',
        str(ROOT / 'Sources/tgapi/RecordingInputLayout.m'), '-o', str(obj),
    ], env=environment, check=True)
    binary = work / 'tests'
    subprocess.run([
        'xcrun', 'swiftc', '-parse-as-library', '-target', target, '-sdk', str(sdk),
        '-F', str(frameworks), '-framework', 'UIKit', '-framework', 'QuartzCore',
        '-Xlinker', '-rpath', '-Xlinker', '/System/iOSSupport/System/Library/Frameworks',
        str(ROOT / 'Sources/tgapi/HostValueReader.swift'),
        str(ROOT / 'Sources/tgapi/RecordingControls.swift'),
        str(ROOT / 'Tests/recording_input_layout.swift'), str(obj), '-o', str(binary),
    ], env=environment, check=True)
    subprocess.run([str(binary)], check=True, timeout=30)
