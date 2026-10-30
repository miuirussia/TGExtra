#!/usr/bin/env python3
"""Exercise the production media downloader with an isolated cache and server."""
import argparse
from pathlib import Path
import subprocess
import tempfile

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--sanitize', action='store_true', help='Run with AddressSanitizer')
args = parser.parse_args()
flags = ['-g', '-fsanitize=address', '-fno-omit-frame-pointer'] if args.sanitize else []

root = Path(__file__).resolve().parent.parent
with tempfile.TemporaryDirectory(prefix='tgextra-paid-download-') as directory:
    binary = Path(directory) / 'tests'
    subprocess.run([
        'clang', *flags,
        '-fobjc-arc', '-Werror', '-I', str(root / 'Sources/tgapiC/include'),
        '-framework', 'Foundation', str(root / 'Sources/tgapi/PaidMediaDownload.m'),
        str(root / 'Tests/paid_media_download.m'), '-o', str(binary),
    ], check=True)
    subprocess.run([str(binary)], check=True, timeout=30)
