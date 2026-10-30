#!/usr/bin/env python3
"""Exercise production word diffs, plus the native history screen when Catalyst is available."""
import os
from pathlib import Path
import platform
import subprocess
import tempfile

root = Path(__file__).resolve().parent.parent
ui = root / 'Sources/tgapi/UI'
with tempfile.TemporaryDirectory(prefix='tgextra-history-diff-') as directory:
    work = Path(directory)
    binary = work / 'diff-tests'
    sources = [str(ui / 'EditHistoryDiff.m'), str(root / 'Tests/edit_history_diff.m')]
    subprocess.run(['clang', '-fobjc-arc', '-Werror', '-I', str(ui), '-framework', 'Foundation',
                    *sources, '-o', str(binary)], check=True)
    subprocess.run([str(binary)], check=True, timeout=30)

    environment = dict(os.environ)
    xcode = Path('/Applications/Xcode.app/Contents/Developer')
    if 'DEVELOPER_DIR' not in environment and xcode.exists():
        environment['DEVELOPER_DIR'] = str(xcode)
    sdk = Path(subprocess.check_output(['xcrun', '--sdk', 'macosx', '--show-sdk-path'],
                                      env=environment, text=True).strip())
    frameworks = sdk / 'System/iOSSupport/System/Library/Frameworks'
    if not (frameworks / 'UIKit.framework/Headers/UIKit.h').exists():
        print('SKIP history UIKit test: requires Mac Catalyst SDK')
    else:
        (work / 'roothide.h').write_text('#define jbroot(path) (path)\n')
        subprocess.run([
            'xcrun', 'clang', '-target', f'{platform.machine()}-apple-ios17.0-macabi', '-isysroot', str(sdk),
            '-iframework', str(frameworks), '-F', str(frameworks), '-fobjc-arc', '-Werror',
            '-Wno-deprecated-declarations', '-Wno-arc-performSelector-leaks', '-DTGEXTRA_UIKIT',
            '-I', str(ui), '-I', str(work), '-framework', 'UIKit', '-framework', 'Foundation', '-framework', 'CoreGraphics',
            '-Wl,-rpath,/System/iOSSupport/System/Library/Frameworks',
            *sources, str(ui / 'EditHistoryViewController.m'), '-o', str(binary),
        ], env=environment, check=True)
        subprocess.run([str(binary)], check=True, timeout=30)
