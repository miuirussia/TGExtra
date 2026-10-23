#!/usr/bin/env python3
import hashlib
import json
from pathlib import Path
import plistlib
import sys
import tempfile
import unittest
import zipfile
sys.path.insert(0, str(Path(__file__).resolve().parents[1]/'Tools'))
from package_cyan import package, read_archive, patch_sets
from prepare_rust_patch import apply_prepared


def archive(path, files):
    with zipfile.ZipFile(path, 'w') as output:
        for name, value in files.items():
            output.writestr(name, value)


def variant(name, digest='0'*64, resource=b'metadata'):
    return {f'patches/{name}/patch.json': json.dumps({'binary_patches': [{'path': 'Client', 'sha256': digest, 'edits': [{'offset': 0, 'expected': '00', 'replacement': '01'}]}], 'f': True}),
            f'patches/{name}/inject/TGExtraRustBridge.plist': resource}


class CyanPackagingTests(unittest.TestCase):
    def test_many_clients_share_one_cyan_without_resource_collisions(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            base, merged, output = root/'base.cyan', root/'patches.cyan', root/'output.cyan'
            archive(base, {'config.json': '{"f":true}', 'inject/TGExtra.deb': b'package'})
            files = {'config.json': '{"patch_sets":true}'}
            for index in range(96):
                files.update(variant(str(index), resource=str(index).encode()))
            archive(merged, files)
            package(base, output, merges=[merged])
            entries = read_archive(output)
            self.assertEqual(len(patch_sets(entries)), 96)
            self.assertEqual(entries['inject/TGExtra.deb'], b'package')
            self.assertNotIn('inject/TGExtraRustBridge.plist', entries)
            self.assertTrue(json.loads(entries['config.json'])['patch_sets'])
            # Regeneration replaces one profile, preserving the remaining 95.
            archive(merged, {'config.json': '{"patch_sets":true}', **variant('7', resource=b'updated')})
            package(output, output, merges=[merged])
            self.assertEqual(len(patch_sets(read_archive(output))), 96)
            self.assertEqual(read_archive(output)['patches/7/inject/TGExtraRustBridge.plist'], b'updated')

    def test_repository_patch_collection_and_global_override_rejection(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            base, output, bad = root/'base.cyan', root/'output.cyan', root/'bad.cyan'
            archive(base, {'config.json': '{}'})
            patches = root/'Patches'
            for name, data in variant('telegram').items():
                destination = patches/Path(name).relative_to('patches')
                destination.parent.mkdir(parents=True, exist_ok=True)
                destination.write_bytes(data.encode() if isinstance(data, str) else data)
            package(base, output, patches=patches)
            self.assertEqual(len(patch_sets(read_archive(output))), 1)
            archive(bad, {'config.json': '{"b":"another.bundle"}'})
            before = output.read_bytes()
            with self.assertRaises(ValueError):
                package(output, output, merges=[bad])
            self.assertEqual(output.read_bytes(), before)

    def test_offline_application_checks_digest_and_preimages(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            binary = root/'Client'
            original = b'original bytes'
            binary.write_bytes(original)
            patch = {'path': 'Client', 'sha256': hashlib.sha256(original).hexdigest(), 'edits': [{'offset': 0, 'expected': original[:4].hex(), 'replacement': b'next'.hex()}]}
            metadata = {'ABI': 5}
            apply_prepared(patch, metadata, root)
            self.assertEqual(binary.read_bytes(), b'nextinal bytes')
            self.assertEqual(plistlib.loads((root/'TGExtraRustBridge.plist').read_bytes()), metadata)
            with self.assertRaises(ValueError):
                apply_prepared(patch, metadata, root)
            binary.write_bytes(original)
            patch['edits'][0]['expected'] = '00000000'
            with self.assertRaises(ValueError):
                apply_prepared(patch, metadata, root)
            self.assertEqual(binary.read_bytes(), original)


if __name__ == '__main__':
    unittest.main()
