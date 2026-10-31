#!/usr/bin/env python3
"""Generate secret-chat call-site bridges from reviewed generic arm64 clients."""
import argparse
import json
from pathlib import Path
import struct
import sys
import zipfile

from package_ipatch import document
from payloads import ipatch_payload

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'Tools/RustBridge'))
from macho import MachO, signed

PROFILE = ROOT / 'Patches/secret-chats-v1'
REVIEWED = json.loads((ROOT / 'Tools/SecretChats/reviewed.json').read_text())


def payload_template(name, block, original, source=None):
    return ipatch_payload(source or PROFILE / f'payloads/{name}.c', block,
                          {'_Original': original, '_dlsym': 'import.dlsym'})


def identify(image, client):
    functions = {}
    for name in ('incoming', 'timer', 'screenshotBody', 'consume'):
        fingerprint = REVIEWED[client][name]['fingerprint']
        matches = [(a, b) for a, b in zip(image.starts, image.ends)
                   if b-a == fingerprint['size'] and image.portable_fingerprint(a, b) == fingerprint]
        if len(matches) != 1:
            raise ValueError(f'unrecognized or ambiguous {client} secret-chat {name}: {len(matches)}')
        functions[name] = matches[0]
    return functions


def generate_variant(ipa, client):
    with zipfile.ZipFile(ipa) as archive:
        paths = [n for n in archive.namelist() if n.endswith('/TelegramCoreFramework.framework/TelegramCoreFramework')]
        if len(paths) != 1:
            raise ValueError('expected one TelegramCore image')
        image = MachO(archive.read(paths[0]))
    functions = identify(image, client)
    patch = {'id': 'runtime', 'search': {'roots': ['.'], 'max_candidates': 128, 'max_bytes': 1 << 30},
             'arch': 'arm64', 'header_reserve': 4096, 'anchors': [], 'checks': [], 'edits': [], 'payloads': []}
    anchors, checks = patch['anchors'], patch['checks']
    for name, (a, b) in functions.items():
        anchors.append({'id': name, 'find': {'function': {'fingerprint': image.portable_fingerprint(a, b)}}})
    anchors.append({'id': 'import.dlsym', 'find': {'import_stub': {'import': '_dlsym'}}})
    sites = dict(REVIEWED[client]['sites'])
    screenshot_calls = [(pc, target) for pc, target in image.branches() if target == functions['screenshotBody'][0]]
    if len(screenshot_calls) != 1:
        raise ValueError('expected one screenshot transaction thunk')
    screen_pc, _ = screenshot_calls[0]
    screen_start, screen_end = image.function(screen_pc)
    if image.portable_fingerprint(screen_start, screen_end) != REVIEWED[client]['screenshotThunk']['fingerprint']:
        raise ValueError('screenshot closure ABI changed')
    anchors += [
        {'id': 'screenshotCall', 'find': {'calls': {'to': 'screenshotBody', 'instruction': 'b'}}, 'count': 1},
        {'id': 'screenshotThunk', 'find': {'containing_function': {'from': 'screenshotCall'}}},
    ]
    checks.append({'id': 'verify.screenshotThunk', 'at': {'anchor': 'screenshotThunk'},
                   'assert': {'function': {'fingerprint': REVIEWED[client]['screenshotThunk']['fingerprint']}}})
    sites['screenshot'] = {'within': 'screenshotThunk', 'offset': screen_pc-screen_start}
    functions['screenshotThunk'] = (screen_start, screen_end)
    values = {'ABI': {'type': 'uint', 'integer': 1}, 'UUID': {'type': 'uuid'}}
    for name, site in sites.items():
        pc = functions[site['within']][0]+site['offset']
        word = image.u32(image.offset(pc))
        if word & 0x7c000000 != 0x14000000:
            raise ValueError(f'{name} is no longer a direct branch')
        instruction = 'bl' if word >> 31 else 'b'
        target = pc+signed(word & 0x3ffffff, 26)*4
        at, original, block = 'call.'+name, 'original.'+name, 'bridge.'+name
        anchors += [
            {'id': at, 'find': {'select': {'from': site['within'], 'index': 0}}, 'offset_bytes': site['offset']},
            {'id': original, 'find': {'branch_target': {'from': at, 'instruction': instruction}}},
        ]
        if image.text <= target < image.text+image.textsize:
            a, b = image.function(target)
            if a != target:
                raise ValueError('original must be a function entry')
            if name == 'consume' and image.portable_fingerprint(a, b) != REVIEWED[client]['consumeLookup']['fingerprint']:
                raise ValueError('content-consumption namespace ABI changed')
            assertion = {'function': {'fingerprint': image.portable_fingerprint(a, b)}}
        else:
            # Imported Postbox stubs retain their exact reviewed slot, including
            # ADRP/LDR bytes. Relinks changing these need another profile review.
            offset = image.offset(target)
            assertion = {'bytes': {'expected': image.data[offset:offset+12].hex()}}
        checks += [
            {'id': 'verify.original.'+name, 'at': {'anchor': original}, 'assert': assertion},
            {'id': 'verify.call.'+name, 'at': {'anchor': at},
             'assert': {'branch': {'to': original, 'instruction': instruction}}},
        ]
        payload = 'deletion' if name in ('delete', 'clear') else name
        code, relocations = payload_template(payload, block, original)
        (PROFILE / f'payloads/{payload}.bin').write_bytes(code)
        patch['payloads'].append({'id': block, 'source': f'payloads/{payload}.bin', 'size': len(code),
                                  'alignment': 4, 'permissions': 'rx', 'near': at,
                                  'max_distance': 134217724, 'relocations': relocations})
        patch['edits'].append({'id': 'redirect.'+name, 'at': {'anchor': at},
                               'expect': {'bytes': struct.pack('<I', word).hex()},
                               'replace': {'bytes': '00000094' if instruction == 'bl' else '00000014',
                                           'relocations': [{'type': instruction, 'offset': 0, 'anchor': block}]}})
        values[name+'Call'] = {'type': 'image_offset', 'anchor': at}
        values[name+'Bridge'] = {'type': 'image_offset', 'anchor': block}
    patch['generated_resources'] = [{'destination': 'TGExtraSecretChats.plist', 'arch': 'arm64', 'values': values}]
    return {'id': 'secret-chats-'+client+'-v1', 'description': 'Secret Chat Protection',
            'bundle_ids': ['ph.telegra.Telegraph' if client == 'telegram' else 'app.swiftgram.ios'], 'binaries': [patch]}


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--telegram', type=Path, required=True)
    parser.add_argument('--swiftgram', type=Path, required=True)
    args = parser.parse_args()
    variants = [generate_variant(args.telegram, 'telegram'), generate_variant(args.swiftgram, 'swiftgram')]
    (PROFILE / 'patch.json').write_text(json.dumps(document('Secret Chat Protection', variants), indent=2)+'\n')
