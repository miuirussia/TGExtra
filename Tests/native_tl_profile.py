#!/usr/bin/env python3
"""Check readable native bridges, conservative ABI gates and real iPatch plans."""
import base64
import hashlib
import json
import plistlib
import os
from pathlib import Path
import re
import struct
import subprocess
import sys
import tempfile
import unittest
import zipfile

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT/'Tools'))
from prepare_native_tl import identify, matcher, payload_template, MachO
from package_ipatch import write_archive
PROFILE = ROOT/'Patches/native-tl-v1'


class NativeTLProfileTests(unittest.TestCase):
    def test_compiled_c_matches_shipped_payload(self):
        profile = json.loads((PROFILE/'patch.json').read_text())['components'][0]['variants'][0]['binaries'][0]
        for name in ('constructor', 'result'):
            code, relocations = payload_template(name)
            self.assertEqual(code, (PROFILE/f'payloads/{name}.bin').read_bytes())
            block = next(b for b in profile['payloads'] if b['id'] == 'bridge.'+name)
            self.assertEqual(block['relocations'], relocations)
            self.assertEqual(block['size'], len(code))
        constructor = next(a for a in profile['anchors'] if a['id'] == 'constructorCalls')
        self.assertEqual((constructor['count'], constructor['find']['calls']['within']), (1, 'topLevel'))
        self.assertEqual(next(a['count'] for a in profile['anchors'] if a['id'] == 'resultCalls'), 1)
        self.assertEqual([a['find']['import_stub']['import'] for a in profile['anchors'] if 'import_stub' in a['find']], ['_dlsym'])

    def test_reviewed_images_and_runtime_matcher(self):
        images = list((ROOT/'packages').glob('*_v13.1.1.ipa'))
        if not images: self.skipTest('reference IPAs are not present')
        include = (ROOT/'Sources/tgapiC/NativeTLProfile.inc').read_text()
        patterns = {}
        for name, body in re.findall(r'native_(\w+)\[\]\[2\] = \{(.*?)\n};', include, re.S):
            patterns[name] = [(int(a, 16), int(b, 16)) for a, b in re.findall(r'\{0x([0-9a-f]+), 0x([0-9a-f]+)}', body)]
        for ipa in images:
            with zipfile.ZipFile(ipa) as archive:
                name = next(n for n in archive.namelist() if n.endswith('/TelegramCoreFramework.framework/TelegramCoreFramework'))
                image = MachO(archive.read(name))
            functions = identify(image)
            for name in ('constructor', 'result', 'body'):
                start, end = functions[name]
                raw = image.data[image.offset(start):image.offset(start)+end-start]
                self.assertEqual(matcher(raw), patterns[name], (ipa.name, name))
            # An ordinary object-layout offset must remain checked, unlike a
            # relocation. This is the type-index load in TLParseConstructor.
            start, end = functions['constructor']
            raw = bytearray(image.data[image.offset(start):image.offset(start)+end-start])
            words = list(struct.unpack('<'+'I'*(len(raw)//4), raw))
            index = words.index(0x79401ac8)
            self.assertEqual(patterns['constructor'][index][1], 0xffffffff)
            mutated = words[index] ^ 0x400
            self.assertNotEqual(mutated & patterns['constructor'][index][1], patterns['constructor'][index][0])
            subprocess.run([sys.executable, str(ROOT/'Tools/prepare_native_tl.py'), str(ipa), '--check'], check=True)

    @unittest.skipUnless(os.environ.get('IPATCH_ENGINE_CLI'), 'requires the real iPatch engine CLI')
    def test_engine_plans_both_reference_clients(self):
        profile = json.loads((PROFILE/'patch.json').read_text())
        files = {b['source']: (PROFILE/b['source']).read_bytes() for b in profile['components'][0]['variants'][0]['binaries'][0]['payloads']}
        with tempfile.TemporaryDirectory(prefix='tgextra-native-profile-') as directory:
            package = Path(directory)/'native.ipatch'
            write_archive(package, profile, files)
            images = list((ROOT/'packages').glob('*_v13.1.1.ipa'))
            if not images: self.skipTest('reference IPAs are not present')
            for ipa in images:
                result = subprocess.run([os.environ['IPATCH_ENGINE_CLI'], '-dry-run', '-ipa', str(ipa), '-package', str(package)],
                                        capture_output=True, text=True, check=True)
                value = json.loads(result.stdout)
                self.assertFalse(value.get('error'), value)
                self.assertEqual(len(value['plan']['patches']), 1)
                self.assertIn('TGExtraNativeTL.plist', value['plan']['generated_resources'])
                plan = value['plan']
                patch = plan['patches'][0]
                with zipfile.ZipFile(ipa) as archive:
                    binary = next(n for n in archive.namelist() if n.endswith('/'+patch['path']))
                    original = archive.read(binary)
                self.assertEqual(hashlib.sha256(original).hexdigest(), patch['sha256'])
                image = MachO(original)
                patched = bytearray(original)
                for edit in patch['edits']:
                    offset = edit['offset']
                    expected = bytes.fromhex(edit['expected'])
                    replacement = bytes.fromhex(edit['replacement'])
                    self.assertEqual(patched[offset:offset+len(expected)], expected)
                    self.assertEqual(len(expected), len(replacement))
                    patched[offset:offset+len(expected)] = replacement
                # Apply the exact engine plan to an extracted copy, then verify
                # the same metadata and branches that gate runtime activation.
                target = Path(directory)/ipa.stem
                target.write_bytes(patched)
                patched_image = MachO(target.read_bytes())
                metadata = plistlib.loads(base64.b64decode(plan['generated_resources']['TGExtraNativeTL.plist']))
                self.assertEqual(metadata['ABI'], 1)
                self.assertEqual(metadata['UUID'], image.uuid)
                base = next(vm for name, vm, _, _ in image.segments if name == '__TEXT')
                functions = identify(image)
                branches = dict(patched_image.branches())
                for name in ('constructor', 'result'):
                    self.assertEqual(metadata[name]+base, functions[name][0])
                    self.assertEqual(branches[base+metadata[name+'Call0']], base+metadata['bridge.'+name])



if __name__ == '__main__': unittest.main()
