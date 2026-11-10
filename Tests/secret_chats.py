#!/usr/bin/env python3
"""Execute secret-chat policies, native bridges, and reviewed iPatch plans."""
import json
import base64
import ctypes
import os
from pathlib import Path
import platform
import plistlib
import struct
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch
import zipfile

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'Tools'))
from prepare_secret_chats import PROFILE, MachO, generate_variant, identify, payload_template
import prepare_secret_chats as secret
from package_ipatch import write_archive
from payloads import link_payload
from macho import page_address


class SecretChatTests(unittest.TestCase):
    def test_policies(self):
        with tempfile.TemporaryDirectory(prefix='tgextra-secret-policy-') as directory:
            binary = str(Path(directory) / 'tests')
            subprocess.run(['swiftc', str(ROOT/'Sources/tgapi/HostValueReader.swift'),
                            str(ROOT/'Sources/tgapi/SecretChatPolicy.swift'), str(ROOT/'Tests/secret_chats.swift'),
                            '-o', binary], check=True)
            subprocess.run([binary], check=True)
            library = str(Path(directory) / 'policy.dylib')
            subprocess.run(['swiftc', '-O', '-whole-module-optimization', '-emit-library',
                            str(ROOT/'Sources/tgapi/HostValueReader.swift'),
                            str(ROOT/'Sources/tgapi/SecretChatPolicy.swift'), '-o', library], check=True)
            callback = ctypes.CDLL(library).TGExtraSecretChatShouldBlock
            callback.argtypes = [ctypes.c_int32, ctypes.c_int32]
            callback.restype = ctypes.c_int32
            self.assertEqual(callback(99, 3), 0, 'The optimized library exports the callback for dlsym')

    @unittest.skipUnless(platform.machine() == 'arm64', 'native arm64 payload execution requires Apple Silicon')
    def test_production_bridges(self):
        with tempfile.TemporaryDirectory(prefix='tgextra-secret-bridge-') as directory:
            for name, event in [('screenshot', 0), ('deletion', 1), ('clear', 1), ('timer', 2), ('consume', 3)]:
                for missing in (False, True):
                    binary = str(Path(directory) / (name+str(missing)))
                    subprocess.run(['clang', '-O2', '-Werror', '-Wl,-export_dynamic', f'-DEVENT={event}',
                                    *(['-DDELETION_BRIDGE'] if name == 'deletion' else []),
                                    *(['-DCLEAR_BRIDGE'] if name == 'clear' else []),
                                    *(['-DEXPIRY_BRIDGE'] if name == 'timer' else []),
                                    *(['-DMISSING_RUNTIME'] if missing else []),
                                    str(ROOT/'Tests/secret_chat_gate.c'), str(PROFILE/f'payloads/{name}.c'),
                                    '-o', binary], check=True)
                    subprocess.run([binary], check=True)

    def test_payloads_match_profile(self):
        document = json.loads((PROFILE/'patch.json').read_text())
        for variant in document['components'][0]['variants']:
            patch, = variant['binaries']
            self.assertEqual(len(patch['edits']), 5)
            for block in patch['payloads']:
                name = Path(block['source']).stem
                code, relocations = payload_template(name, block['id'], 'original.'+block['id'].removeprefix('bridge.'))
                self.assertEqual(code, (PROFILE/block['source']).read_bytes())
                self.assertEqual(relocations, block['relocations'])
                self.assertEqual(len(code), block['size'])

    def test_reviewed_clients_and_changed_abi(self):
        for client, filename in [('telegram', 'Telegram_v13.2.1.ipa'), ('swiftgram', 'Swiftgram_v13.1.3_360.ipa')]:
            ipa = ROOT/'packages'/filename
            if not ipa.exists(): continue
            with self.subTest(client=client):
                variant = generate_variant(ipa, client)
                expected = next(v for v in json.loads((PROFILE/'patch.json').read_text())['components'][0]['variants']
                                if v['id'] == variant['id'])
                self.assertEqual(variant, expected)
                with zipfile.ZipFile(ipa) as archive:
                    path = next(n for n in archive.namelist() if n.endswith('/TelegramCoreFramework.framework/TelegramCoreFramework'))
                    image = MachO(archive.read(path))
                functions = identify(image, client)
                # Mutate the namespace comparison inside the expiry callback.
                a, b = functions['timer']
                position = image.data.index(bytes.fromhex('1f0c0071'), image.offset(a), image.offset(a)+b-a)
                data = bytearray(image.data)
                data[position] ^= 4
                with self.assertRaises(ValueError): identify(MachO(bytes(data)), client)

    def test_retired_swiftgram_profile_is_rejected(self):
        ipa = ROOT/'packages/Swiftgram_v13.1.1.ipa'
        if not ipa.is_file():
            self.skipTest('retired reference IPA is not present')
        with self.assertRaisesRegex(ValueError, 'swiftgram secret-chat incoming'):
            generate_variant(ipa, 'swiftgram')

    def test_changed_original_targets_are_rejected_with_unchanged_callers(self):
        references = [(client, ROOT/'packages'/filename) for client, filename in
                      [('telegram', 'Telegram_v13.2.1.ipa'), ('swiftgram', 'Swiftgram_v13.1.3_360.ipa')]
                      if (ROOT/'packages'/filename).is_file()]
        if not references:
            self.skipTest('reference IPAs are not present')
        with tempfile.TemporaryDirectory(prefix='tgextra-secret-originals-') as directory:
            root = Path(directory)
            profile = root/'profile'
            (profile/'payloads').mkdir(parents=True)
            for client, ipa in references:
                with zipfile.ZipFile(ipa) as archive:
                    path = next(n for n in archive.namelist()
                                if n.endswith('/TelegramCoreFramework.framework/TelegramCoreFramework'))
                    original = archive.read(path)
                image = MachO(original)
                functions = identify(image, client)
                branches = dict(image.branches())
                for name in ('delete', 'clear', 'timer', 'consume'):
                    with self.subTest(client=client, target=name):
                        site = secret.REVIEWED[client]['sites'][name]
                        target = branches[functions[site['within']][0]+site['offset']]
                        changed = bytearray(original)
                        changed[image.offset(target)] ^= 1
                        self.assertEqual(identify(MachO(changed), client), functions,
                                         'The reviewed caller alone must not validate its target')
                        changed_ipa = root/'changed.ipa'
                        with zipfile.ZipFile(changed_ipa, 'w') as archive:
                            archive.writestr(path, changed)
                        with patch.object(secret, 'PROFILE', profile), \
                                patch.object(secret, 'payload_template', return_value=(b'', [])):
                            with self.assertRaises(ValueError):
                                generate_variant(changed_ipa, client)
                        self.assertEqual(list((profile/'payloads').iterdir()), [],
                                         'Rejected inputs must not publish partial payloads')

    def test_changed_import_bindings_are_rejected_by_generator_and_engine(self):
        references = [(client, ROOT/'packages'/filename) for client, filename in
                      [('telegram', 'Telegram_v13.2.1.ipa'), ('swiftgram', 'Swiftgram_v13.1.3_360.ipa')]
                      if (ROOT/'packages'/filename).is_file()]
        if not references:
            self.skipTest('reference IPAs are not present')
        with tempfile.TemporaryDirectory(prefix='tgextra-secret-bindings-') as directory:
            root = Path(directory)
            profile = root/'profile'
            (profile/'payloads').mkdir(parents=True)
            value = json.loads((PROFILE/'patch.json').read_text())
            files = {b['source']: (PROFILE/b['source']).read_bytes() for v in value['components'][0]['variants']
                     for p in v['binaries'] for b in p['payloads']}
            package = root/'secret.ipatch'
            write_archive(package, value, files)
            for client, ipa in references:
                with zipfile.ZipFile(ipa) as archive:
                    path = next(n for n in archive.namelist()
                                if n.endswith('/TelegramCoreFramework.framework/TelegramCoreFramework'))
                    original = archive.read(path)
                    app = path.split('/Frameworks/')[0]
                    info = archive.read(app+'/Info.plist')
                    main_path = app+'/'+plistlib.loads(info)['CFBundleExecutable']
                    main = archive.read(main_path)
                image = MachO(original)
                functions = identify(image, client)
                branches = dict(image.branches())
                engine = os.environ.get('IPATCH_ENGINE_CLI')
                if engine:
                    baseline = root/'baseline.ipa'
                    with zipfile.ZipFile(baseline, 'w') as archive:
                        archive.writestr(path, original)
                        archive.writestr(app+'/Info.plist', info)
                        archive.writestr(main_path, main)
                    result = subprocess.run([engine, '-dry-run', '-ipa', str(baseline), '-package', str(package)],
                                            capture_output=True, text=True, timeout=180)
                    self.assertEqual(result.returncode, 0, result.stdout+result.stderr)
                    self.assertEqual(len(json.loads(result.stdout)['plan']['patches']), 1)
                position = 32
                for _ in range(image.u32(16)):
                    command, size = struct.unpack_from('<II', original, position)
                    if command == 0x80000034:
                        fixups = image.u32(position+8)
                    position += size
                self.assertEqual(image.u32(fixups+20), 1, 'Reviewed fixtures use compact import records')
                imports, symbols = image.u32(fixups+8), image.u32(fixups+12)
                slots, stubs = {}, {}
                for name in ('clear', 'timer'):
                    site = secret.REVIEWED[client]['sites'][name]
                    stubs[name] = branches[functions[site['within']][0]+site['offset']]
                    adrp, load = struct.unpack_from('<II', original, image.offset(stubs[name]))
                    slots[name] = image.offset(page_address(stubs[name], adrp)+(load >> 10 & 4095)*8)
                for name, slot in slots.items():
                    pointer, = struct.unpack_from('<Q', original, slot)
                    record = fixups+imports+(pointer & 0xffffff)*4
                    symbol = fixups+symbols+(image.u32(record) >> 9)
                    for mutation in ('pointer ordinal', 'dylib ordinal', 'symbol name'):
                        with self.subTest(client=client, target=name, mutation=mutation):
                            changed = bytearray(original)
                            if mutation == 'pointer ordinal':
                                other = slots['timer' if name == 'clear' else 'clear']
                                other_pointer, = struct.unpack_from('<Q', original, other)
                                struct.pack_into('<Q', changed, slot, pointer & ~0xffffff | other_pointer & 0xffffff)
                            elif mutation == 'dylib ordinal':
                                changed[record] = 1  # MtProtoKit, preserving the symbol and stub bytes.
                            else:
                                changed[symbol+1] ^= 1
                            at = image.offset(stubs[name])
                            self.assertEqual(changed[at:at+12], original[at:at+12])
                            self.assertEqual(identify(MachO(changed), client), functions)
                            changed_ipa = root/'changed.ipa'
                            with zipfile.ZipFile(changed_ipa, 'w') as archive:
                                archive.writestr(path, changed)
                                archive.writestr(app+'/Info.plist', info)
                                archive.writestr(main_path, main)
                            with patch.object(secret, 'PROFILE', profile), \
                                    patch.object(secret, 'payload_template', return_value=(b'', [])):
                                with self.assertRaisesRegex(ValueError, 'import binding'):
                                    generate_variant(changed_ipa, client)
                            self.assertEqual(list((profile/'payloads').iterdir()), [])
                            if engine and name == 'clear':
                                result = subprocess.run([engine, '-dry-run', '-ipa', str(changed_ipa),
                                                         '-package', str(package)], capture_output=True, text=True, timeout=180)
                                self.assertNotEqual(result.returncode, 0, result.stdout+result.stderr)
                                self.assertTrue(json.loads(result.stdout).get('error'), result.stdout)

    @unittest.skipUnless(os.environ.get('IPATCH_ENGINE_CLI'), 'requires iPatch v4 CLI')
    def test_engine_plans(self):
        document = json.loads((PROFILE/'patch.json').read_text())
        files = {b['source']: (PROFILE/b['source']).read_bytes() for v in document['components'][0]['variants']
                 for p in v['binaries'] for b in p['payloads']}
        with tempfile.TemporaryDirectory(prefix='tgextra-secret-plan-') as directory:
            package = Path(directory)/'secret.ipatch'
            write_archive(package, document, files)
            for filename in ('Telegram_v13.2.1.ipa', 'Swiftgram_v13.1.3_360.ipa'):
                ipa = ROOT/'packages'/filename
                if not ipa.exists(): continue
                result = subprocess.run([os.environ['IPATCH_ENGINE_CLI'], '-dry-run', '-ipa', str(ipa), '-package', str(package)],
                                        capture_output=True, text=True, check=True)
                value = json.loads(result.stdout)
                self.assertFalse(value.get('error'), value)
                patch, = value['plan']['patches']
                self.assertEqual(patch['path'], 'Frameworks/TelegramCoreFramework.framework/TelegramCoreFramework')
                self.assertIn('TGExtraSecretChats.plist', value['plan']['generated_resources'])
                with zipfile.ZipFile(ipa) as archive:
                    path = next(n for n in archive.namelist() if n.endswith('/'+patch['path']))
                    original = archive.read(path)
                image = MachO(original)
                patched = bytearray(original)
                for edit in patch['edits']:
                    offset = edit['offset']
                    expected = bytes.fromhex(edit['expected'])
                    replacement = bytes.fromhex(edit['replacement'])
                    self.assertEqual(patched[offset:offset+len(expected)], expected)
                    self.assertEqual(len(expected), len(replacement))
                    patched[offset:offset+len(expected)] = replacement
                linked = value['plan']['profiles'][0]['plan']
                addresses = {key: values[0]['va'] for key, values in linked['anchors'].items()}
                variant = document['components'][0]['variants'][0 if filename.startswith('Telegram') else 1]
                for block in variant['binaries'][0]['payloads']:
                    address = linked['anchors'][block['id']][0]
                    expected = link_payload(files[block['source']], block['relocations'], address['va'], addresses)
                    self.assertEqual(patched[address['file_offset']:address['file_offset']+block['size']], expected)
                metadata = plistlib.loads(base64.b64decode(value['plan']['generated_resources']['TGExtraSecretChats.plist']))
                self.assertEqual(metadata['ABI'], 1)
                self.assertEqual(metadata['UUID'], image.uuid)
                base = next(vm for name, vm, _, _ in image.segments if name == '__TEXT')
                branches = dict(MachO(patched).branches())
                for name in ('delete', 'clear', 'timer', 'consume', 'screenshot'):
                    self.assertEqual(branches[base+metadata[name+'Call']], base+metadata[name+'Bridge'])


if __name__ == '__main__': unittest.main()
