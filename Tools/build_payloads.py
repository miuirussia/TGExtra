#!/usr/bin/env python3
"""Rebuild existing reviewed profiles' C payloads without reference IPAs (macOS/Clang)."""
import argparse
import hashlib
import json
from pathlib import Path

from payloads import compile_payload
from prepare_native_tl import payload_template as native_payload
from prepare_rust_patch import SELECTORS
from portable import payload_template as rust_payload

ROOT = Path(__file__).resolve().parents[1]


def rebuild(patches, check=False):
    def write(path, data):
        if check:
            if path.read_bytes() != data:
                raise ValueError(f'stale C payload: {path}; run python3 Tools/build_payloads.py')
        else:
            path.write_bytes(data)

    for path in sorted(patches.glob('*/patch.json')):
        item = json.loads(path.read_text())
        identifier = path.parent.name
        if identifier == 'swiftgram-pro-status-v1':
            code, fixups = compile_payload(path.parent/'payloads/status.c')
            if fixups or len(code) != 20:
                raise ValueError('Swift witness adapter must remain exactly 20 bytes without fixups')
            write(path.parent/'payloads/status.bin', code)
            print(('Checked ' if check else 'Built ')+identifier)
            continue
        if identifier != 'native-tl-v1' and not identifier.startswith('rust-abi5-'):
            continue
        patch, = item['binary_patches']
        files = {}
        for block in patch['profile']['blocks']:
            name = block['name'].removeprefix('bridge.')
            source = path.parent/Path(block['source']).with_suffix('.c')
            if identifier == 'native-tl-v1':
                code, relocations = native_payload(name, source=source)
            else:
                code, relocations = rust_payload(*SELECTORS[name], name, source=source)
            block.update(size=len(code), relocations=relocations)
            files[block['source']] = code
        destination = path.parent
        if identifier.startswith('rust-abi5-'):
            identity = {'patch': patch, 'payloads': {source: hashlib.sha256(data).hexdigest()
                                                   for source, data in files.items()}}
            digest = hashlib.sha256(json.dumps(identity, sort_keys=True, separators=(',', ':')).encode()).hexdigest()[:16]
            destination = patches/('rust-abi5-'+digest)
            item['name'] = 'Rust MTProto ABI 5 / '+digest
            if check and destination != path.parent:
                raise ValueError(f'stale Rust profile identity: {path.parent}')
            if not check and destination != path.parent and destination.exists():
                raise ValueError(f'Rust profile destination already exists: {destination}')
        for source, data in files.items():
            write(path.parent/source, data)
        write(path, (json.dumps(item, indent=2)+'\n').encode())
        if not check and destination != path.parent:
            path.parent.rename(destination)
        print(('Checked ' if check else 'Built ')+destination.name)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--check', action='store_true')
    args = parser.parse_args()
    rebuild(ROOT/'Patches', args.check)
