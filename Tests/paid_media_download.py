#!/usr/bin/env python3
"""Exercise the production media downloader with an isolated cache and server."""
import os
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parent.parent
with tempfile.TemporaryDirectory(prefix='tgextra-paid-download-') as directory:
    binary = Path(directory) / 'tests'
    subprocess.run([
        'clang', '-fobjc-arc', '-Werror', '-I', str(root / 'Sources/tgapiC/include'),
        '-framework', 'Foundation', str(root / 'Sources/tgapi/PaidMediaDownload.m'),
        str(root / 'Tests/paid_media_download.m'), '-o', str(binary),
    ], check=True)
    subprocess.run([str(binary)], env={**os.environ, 'TMPDIR': directory + '/'},
                   check=True, timeout=30)
