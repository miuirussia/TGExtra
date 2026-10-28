#!/usr/bin/env python3
"""Portable fingerprint regressions and execution of engine-linked ObjC thunks."""
import json
import os
from pathlib import Path
import platform
import plistlib
import shutil
import struct
import subprocess
import sys
import tempfile
import unittest
import zipfile

sys.path.insert(0, str(Path(__file__).resolve().parents[1]/'Tools'))
from prepare_rust_patch import SELECTORS, thunk, engine_plan, apply_engine_plan
from RustBridge.macho import MachO
from portable import payload_template
from package_ipatch import write_archive
from build_payloads import rebuild


def fingerprint_image(words, offset=0x1000):
    image = MachO.__new__(MachO)
    image.data = bytearray(0x3000)
    image.segments = [('__TEXT', 0x100000000, 0, 0x3000)]
    image.vm_segments = [(0x100000000, 0x3000, 5), (0x100004000, 0x1000, 3)]
    struct.pack_into('<'+'I'*len(words), image.data, offset, *words)
    return image, 0x100000000+offset, 0x100000000+offset+4*len(words)


class PortableRustTests(unittest.TestCase):
    def test_rebuild_uses_adjacent_c_and_preserves_host_checks(self):
        original = next((Path(__file__).resolve().parents[1]/'Patches').glob('rust-abi5-*'))
        with tempfile.TemporaryDirectory(prefix='tgextra-c-rebuild-') as directory:
            patches = Path(directory)
            profile = patches/original.name
            shutil.copytree(original, profile)
            before = json.loads((profile/'patch.json').read_text())['binary_patches'][0]['profile']
            source = profile/'payloads/send.c'
            changed = source.read_text().replace('"TGExtraRustBridge"', '"AbsentRustBridge!"')
            source.write_text(changed)
            rebuild(patches)
            rebuilt, = patches.glob('rust-abi5-*')
            self.assertNotEqual(profile, rebuilt)
            after = json.loads((rebuilt/'patch.json').read_text())['binary_patches'][0]['profile']
            for key in ('anchors', 'checks', 'edits', 'generated_resources'):
                self.assertEqual(before[key], after[key])
            self.assertEqual((rebuilt/'payloads/send.c').read_text(), changed)
            self.assertIn(b'AbsentRustBridge!\0', (rebuilt/'payloads/send.bin').read_bytes())
            rebuild(patches, check=True)

    def test_built_payloads_match_c_source(self):
        profiles = Path(__file__).resolve().parents[1]/'Patches'
        sets = list(profiles.glob('rust-abi5-*/patch.json'))
        self.assertTrue(sets)
        for path in sets:
            profile = json.loads(path.read_text())['binary_patches'][0]['profile']
            self.assertEqual(len(profile['blocks']), len(SELECTORS))
            for name, (selector, arguments) in SELECTORS.items():
                block = next(b for b in profile['blocks'] if b['name'] == 'bridge.'+name)
                code, relocations = payload_template(selector, arguments, name,
                                                     source=path.parent/Path(block['source']).with_suffix('.c'))
                self.assertEqual(code, (path.parent/block['source']).read_bytes(), (path.parent.name, name))
                self.assertEqual(relocations, block['relocations'])
                self.assertEqual(len(code), block['size'])
        self.assertTrue(all(path.with_suffix('.c').is_file() for path in profiles.rglob('*.bin')))

    def test_fingerprints_keep_local_control_flow_and_semantic_constants(self):
        image, start, end = fingerprint_image([0x14000001, 0x91000421, 0xD65F03C0])
        original = image.portable_fingerprint(start, end)
        struct.pack_into('<I', image.data, 0x1000, 0x14000002)
        self.assertNotEqual(original, image.portable_fingerprint(start, end))
        struct.pack_into('<II', image.data, 0x1000, 0x14000001, 0x91000821)
        self.assertNotEqual(original, image.portable_fingerprint(start, end))

    def test_fingerprints_normalize_mapped_external_branches_and_zero_fill_data(self):
        first, start, end = fingerprint_image([0x94000010, 0xF9400400, 0xD65F03C0])
        second, other, last = fingerprint_image([0x94000020, 0xF9400400, 0xD65F03C0], 0x1800)
        self.assertEqual(first.portable_fingerprint(start, end), second.portable_fingerprint(other, last))
        # ADRP from the 0x1000 page to zero-fill __DATA at 0x4000.
        first, start, end = fingerprint_image([0xF0000000, 0x91040000, 0xD65F03C0])
        second, other, last = fingerprint_image([0xF0000000, 0x91080000, 0xD65F03C0], 0x1800)
        self.assertEqual(first.portable_fingerprint(start, end), second.portable_fingerprint(other, last))
        second.vm_segments.pop()
        with self.assertRaises(ValueError):
            second.portable_fingerprint(other, last)

    def test_getters_keep_conditional_displacements(self):
        image, start, end = fingerprint_image([0xB4000040, 0xF9400400, 0xD65F03C0])
        self.assertEqual(image.portable_fingerprint(start, end)['sha256'],
                         '5efb967d07f0ce75f2012bd6ca980b4a2ebb9dafc974af8ec0a25ac78a9bbb49')

    @unittest.skipUnless(os.environ.get('IPATCH_ENGINE_CLI') and platform.system() == 'Darwin' and
                         platform.machine() == 'arm64', 'requires IPATCH_ENGINE_CLI and Apple Silicon macOS')
    def test_engine_links_and_executes_objc_bridge_on_two_layouts(self):
        engine = Path(os.environ['IPATCH_ENGINE_CLI'])
        harness = Path(__file__).with_name('rust_thunks.m')
        with tempfile.TemporaryDirectory(prefix='tgextra-portable-') as directory:
            root = Path(directory)
            previous = None
            for padding in (0x4000, 0x8000):
                app = root/f'Layout{padding}.app'
                app.mkdir()
                executable = app/'Harness'
                asm = root/'thunks.s'
                names = ('1', '2', '3', '4', 'Fallback')
                asm.write_text('\n'.join(f'.text\n.p2align 12\n.globl _RustThunk{name}\n_RustThunk{name}:\n.space 4096'
                                         for name in names)+'\n')
                subprocess.run(['clang', '-fobjc-arc', '-Werror', str(harness), str(asm), '-framework', 'Foundation',
                                f'-Wl,-headerpad,{padding:x}', '-o', str(executable)], check=True)
                original = executable.read_bytes()
                info = plistlib.dumps({'CFBundleIdentifier': 'test.rust.thunks', 'CFBundleExecutable': 'Harness'})
                (app/'Info.plist').write_bytes(info)
                ipa = root/'input.ipa'
                with zipfile.ZipFile(ipa, 'w') as archive:
                    archive.writestr('Payload/Harness.app/Info.plist', info)
                    archive.writestr('Payload/Harness.app/Harness', original)
                anchors = [{'name': name, 'type': 'import_stub', 'import': name}
                           for name in ('_objc_lookUpClass', '_sel_registerName', '_objc_msgSend')]
                blocks, edits, files = [], [], {}
                selectors = ['one:original:', 'two:b:original:', 'three:b:c:original:', 'four:b:c:d:original:']
                for index, name in enumerate(names):
                    arguments = min(index+1, 4)
                    target = 'original'+name
                    code, relocations = payload_template(selectors[arguments-1], arguments, target)
                    if name == 'Fallback':
                        code = code.replace(b'TGExtraRustBridge\0', b'AbsentRustBridge!\0')
                    source = 'payloads/'+name+'.bin'
                    files[source] = code
                    anchors.extend([
                        {'name': target, 'type': 'symbol', 'target': {'type': 'symbol', 'arch': 'arm64', 'name': f'_RustOriginal{arguments}'}},
                        {'name': 'slot'+name, 'type': 'symbol', 'target': {'type': 'symbol', 'arch': 'arm64', 'name': '_RustThunk'+name}},
                    ])
                    blocks.append({'name': 'bridge.'+target, 'source': source, 'size': len(code), 'alignment': 4,
                                   'permissions': 'rx', 'relocations': relocations})
                    edits.append({'anchor': 'slot'+name, 'expected': '00000000', 'replacement': '00000014',
                                  'relocations': [{'type': 'b', 'offset': 0, 'anchor': 'bridge.'+target}]})
                profile = {'arch': 'arm64', 'anchors': anchors, 'blocks': blocks, 'edits': edits,
                           'generated_resources': [{'destination': 'TGExtraRustBridge.plist', 'arch': 'arm64',
                                                    'values': {'ABI': {'type': 'uint', 'integer': 5}, 'UUID': {'type': 'uuid'}}}]}
                package = root/'thunks.ipatch'
                write_archive(package, {'format': 'ipatch', 'version': 2, 'name': 'Native bridge test', 'patch_sets': [
                    {'name': 'thunks', 'bundle_ids': ['test.rust.thunks'], 'binary_patches': [{'path': 'Harness', 'profile': profile}]}]}, files)
                plan = engine_plan(engine, ipa, package)
                self.assertEqual(executable.read_bytes(), original, 'planning modified the input')
                linked = plan['profiles'][0]['plan']
                current = [(edit['offset'], edit['replacement']) for edit in linked['edits']]
                self.assertNotEqual(previous, current)
                previous = current
                # Compare every engine-linked block with the offline C-payload
                # linker before executing the result.
                addresses = {key: value[0]['va'] for key, value in linked['anchors'].items()}
                by_offset = {edit['offset']: bytes.fromhex(edit['replacement']) for edit in linked['edits']}
                for index, name in enumerate(names):
                    arguments = min(index+1, 4)
                    target = 'original'+name
                    block = linked['anchors']['bridge.'+target][0]
                    expected = thunk(block['va'], addresses[target], selectors[arguments-1], arguments,
                                     {key: addresses[key] for key in ('_objc_lookUpClass', '_sel_registerName', '_objc_msgSend')})
                    if name == 'Fallback':
                        expected = expected.replace(b'TGExtraRustBridge\0', b'AbsentRustBridge!\0')
                    self.assertEqual(by_offset[block['file_offset']], expected)
                apply_engine_plan(plan, app, 'Harness')
                subprocess.run(['codesign', '-s', '-', '--force', str(executable)], check=True)
                subprocess.run([str(executable)], check=True)


if __name__ == '__main__':
    unittest.main()
