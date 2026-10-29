#!/usr/bin/env python3
"""Check the production Photos importer without modifying the user's library."""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parent.parent
with tempfile.TemporaryDirectory(prefix='tgextra-paid-import-') as directory:
    binary = Path(directory) / 'tests'
    subprocess.run([
        'clang', '-fobjc-arc', '-Werror', '-DTGEXTRA_TESTING',
        '-I', str(root / 'Tests/Support'), '-framework', 'Foundation',
        str(root / 'Sources/tgapi/PaidMediaImport.m'), str(root / 'Tests/paid_media_import.m'),
        '-o', str(binary),
    ], check=True)
    subprocess.run([str(binary)], check=True, timeout=30)
