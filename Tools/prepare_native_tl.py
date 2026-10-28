#!/usr/bin/env python3
"""Generate reviewed native TL parser bridges and the runtime matcher.

The only hand-maintained identities are normalized function fingerprints. Field
policies stay in MessagePatches.swift; no protocol fields live in machine code.
"""
import argparse
import json
from pathlib import Path
import struct
import sys
import zipfile
from payloads import ipatch_payload
from package_ipatch import document

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / 'Tools/RustBridge'))
from macho import MachO, preserves_register, page_low, signed

REVIEWED = {
    'constructor': (524, '7d44a0542c7ada1e3281075fb9a89a47e3b980c91453c577bfd880ace5de7992'),
    'result': (112, 'db6b281376cc05e44ecfa0eb7a3a2f9e0c099f648504b15b89ea998c20b6f204'),
    'topLevel': (276, '88be5feef6018394f13e1f57b593cbe4e83287a33ceabd1713115449456af266'),
    'body': (1160, '3d37051922e8f7039866eaa979cb3d57b95dab0aaf3e2b39027bdbf44357b276'),
}
ENTRIES = ('constructor', 'result')


def payload_template(name, source=None):
    return ipatch_payload(source if source is not None else ROOT/f'Patches/native-tl-v1/payloads/{name}.c', 'bridge.'+name,
                          {'_Original': name, '_dlsym': 'import.dlsym'})


def identify(image):
    out = {}
    for name, (size, digest) in REVIEWED.items():
        matches = [(a, b) for a, b in zip(image.starts, image.ends) if b-a == size and image.fingerprint(a, b) == digest]
        if len(matches) != 1:
            raise ValueError(f'unrecognized or ambiguous native TL {name}: {len(matches)}')
        out[name] = matches[0]
    if image.starts.index(out['body'][0]) != image.starts.index(out['constructor'][0]) + 1:
        raise ValueError('native TL constructor/body cluster changed')
    if image.starts.index(out['result'][0]) != image.starts.index(out['constructor'][0]) + 3:
        raise ValueError('native TL function-result cluster changed')
    return out


def matcher(code):
    words = list(struct.unpack('<' + 'I'*(len(code)//4), code))
    masks = [0xffffffff]*len(words)
    pages = set()
    for i, word in enumerate(words):
        if word & 0x7c000000 == 0x14000000:
            target = i*4 + signed(word & 0x3ffffff, 26)*4
            if not 0 <= target < len(code): masks[i] = 0xfc000000
            pages.clear()
        elif word & 0x9f000000 == 0x90000000:
            masks[i] = 0x9f00001f
            pages.add(word & 31)
            continue
        elif word >> 5 & 31 in pages:
            register = word >> 5 & 31
            if page_low(word, register) is not None:
                masks[i] = 0xffc003ff
                pages.discard(register)
        pages = {reg for reg in pages if preserves_register(word, reg)}
        if word & 0xff000010 == 0x54000000 or word & 0x7e000000 in (0x34000000, 0x36000000): pages.clear()
    return list(zip([w&m for w,m in zip(words,masks)], masks))


def generate(ipa, output, check=False):
    def write(path, content):
        content = content.encode() if isinstance(content, str) else content
        if check:
            if path.read_bytes() != content: raise ValueError(f'stale generated native profile: {path}')
        else:
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(content)
    with zipfile.ZipFile(ipa) as archive:
        info = []
        for name in archive.namelist():
            if name.endswith('/TelegramCoreFramework.framework/TelegramCoreFramework'):
                image = MachO(archive.read(name))
                info.append((image, identify(image)))
        if len(info) != 1: raise ValueError('expected one native TL image')
    image, functions = info[0]
    profile = {'arch': 'arm64', 'header_reserve': 4096, 'anchors': [], 'checks': [], 'payloads': [], 'edits': []}
    anchors, checks = profile['anchors'], profile['checks']
    for name, (a, b) in functions.items():
        anchors.append({'id': name, 'find': {'function': {'fingerprint': image.portable_fingerprint(a, b)}}})
    for imp in ('_dlsym',):
        anchors.append({'id': 'import.'+imp.lstrip('_'), 'find': {'import_stub': {'import': imp}}})
    branches = list(image.branches())
    values = {'ABI': {'type': 'uint', 'integer': 1}, 'UUID': {'type': 'uuid'}}
    output.mkdir(parents=True, exist_ok=True)
    payloads = output/'payloads'; payloads.mkdir(exist_ok=True)
    arrays = []
    for name in ENTRIES:
        address, end = functions[name]
        code, relocations = payload_template(name)
        write(payloads/f'{name}.bin', code)
        write(payloads/f'{name}.c', (ROOT/f'Patches/native-tl-v1/payloads/{name}.c').read_bytes())
        sites = [(pc, target) for pc, target in branches if target == address and
                 (name != 'constructor' or functions['topLevel'][0] <= pc < functions['topLevel'][1])]
        if len(sites) != 1: raise ValueError(f'expected one root call for {name}')
        anchor = {'id': name+'Calls', 'count': len(sites), 'find': {'calls': {'to': name}}}
        if name == 'constructor': anchor['find']['calls']['within'] = 'topLevel'
        anchors.append(anchor)
        for index, (pc, _) in enumerate(sites):
            at = name+'Call'+str(index)
            anchors.append({'id': at, 'find': {'select': {'from': name+'Calls', 'index': index}}})
            instruction = 'bl' if image.u32(image.offset(pc)) >> 31 else 'b'
            checks.append({'id': 'verify-'+at, 'at': {'anchor': at}, 'assert': {'branch': {'to': name, 'instruction': instruction}}})
            profile['edits'].append({'id': 'redirect-'+at, 'at': {'anchor': at}, 'replace': {
                'bytes': '00000094' if instruction == 'bl' else '00000014',
                'relocations': [{'type': instruction, 'offset': 0, 'anchor': 'bridge.'+name}]}})
            values[at] = {'type': 'image_offset', 'anchor': at}
        profile['payloads'].append({'id': 'bridge.'+name, 'source': 'payloads/'+name+'.bin', 'size': len(code),
            'alignment': 4, 'permissions': 'rx', 'relocations': relocations})
        values[name] = {'type': 'image_offset', 'anchor': name}
        values['bridge.'+name] = {'type': 'image_offset', 'anchor': 'bridge.'+name}
        raw = image.data[image.offset(address):image.offset(address)+end-address]
        arrays.append('static const uint32_t native_'+name+'[][2] = {\n' + ''.join(
            f'    {{0x{word:08x}, 0x{mask:08x}}},\n' for word, mask in matcher(raw)) + '};\n')
    address, end = functions['body']
    raw = image.data[image.offset(address):image.offset(address)+end-address]
    arrays.append('static const uint32_t native_body[][2] = {\n' + ''.join(
        f'    {{0x{word:08x}, 0x{mask:08x}}},\n' for word, mask in matcher(raw)) + '};\n')
    profile['generated_resources'] = [{'destination': 'TGExtraNativeTL.plist', 'arch': 'arm64', 'values': values}]
    package = document('Native TL Decoder', [{'id': 'native-tl-v1', 'description': 'Native TL Decoder',
        'bundle_ids': ['ph.telegra.Telegraph', 'app.swiftgram.ios'], 'binaries': [{'id': 'runtime',
        'search': {'roots': ['.'], 'max_candidates': 128, 'max_bytes': 1 << 30}, **profile}]}])
    write(output/'patch.json', json.dumps(package, indent=2)+'\n')
    write(ROOT/'Sources/tgapiC/NativeTLProfile.inc', '// Generated by Tools/prepare_native_tl.py from reviewed parser bodies.\n' + ''.join(arrays))


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('ipa', type=Path)
    parser.add_argument('--output', type=Path, default=ROOT/'Patches/native-tl-v1')
    parser.add_argument('--check', action='store_true')
    args = parser.parse_args()
    generate(args.ipa, args.output, args.check)
