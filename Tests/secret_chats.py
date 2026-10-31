#!/usr/bin/env python3
"""Execute secret-chat policies, native bridges, and reviewed iPatch plans."""
import json
import ctypes
import os
from pathlib import Path
import platform
import subprocess
import sys
import tempfile
import unittest
import zipfile

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'Tools'))
from prepare_secret_chats import PROFILE, REVIEWED, MachO, generate_variant, identify, payload_template
from package_ipatch import write_archive


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
            for name, event in [('screenshot', 0), ('deletion', 1), ('timer', 2), ('consume', 3)]:
                for missing in (False, True):
                    binary = str(Path(directory) / (name+str(missing)))
                    subprocess.run(['clang', '-O2', '-Werror', '-Wl,-export_dynamic', f'-DEVENT={event}',
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
        for client, filename in [('telegram', 'Telegram_v13.1.2.ipa'), ('swiftgram', 'Swiftgram_v13.1.1.ipa')]:
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

    @unittest.skipUnless(os.environ.get('IPATCH_ENGINE_CLI'), 'requires iPatch v4 CLI')
    def test_engine_plans(self):
        document = json.loads((PROFILE/'patch.json').read_text())
        files = {b['source']: (PROFILE/b['source']).read_bytes() for v in document['components'][0]['variants']
                 for p in v['binaries'] for b in p['payloads']}
        with tempfile.TemporaryDirectory(prefix='tgextra-secret-plan-') as directory:
            package = Path(directory)/'secret.ipatch'
            write_archive(package, document, files)
            for filename in ('Telegram_v13.1.2.ipa', 'Swiftgram_v13.1.1.ipa'):
                ipa = ROOT/'packages'/filename
                if not ipa.exists(): continue
                result = subprocess.run([os.environ['IPATCH_ENGINE_CLI'], '-dry-run', '-ipa', str(ipa), '-package', str(package)],
                                        capture_output=True, text=True, check=True)
                value = json.loads(result.stdout)
                self.assertFalse(value.get('error'), value)
                patch, = value['plan']['patches']
                self.assertEqual(patch['path'], 'Frameworks/TelegramCoreFramework.framework/TelegramCoreFramework')
                self.assertIn('TGExtraSecretChats.plist', value['plan']['generated_resources'])


if __name__ == '__main__': unittest.main()
