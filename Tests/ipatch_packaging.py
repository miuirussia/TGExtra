#!/usr/bin/env python3
import hashlib
import json
from pathlib import Path
import plistlib
import sys
import tempfile
import unittest
from unittest.mock import patch as mock_patch
import zipfile
sys.path.insert(0, str(Path(__file__).resolve().parents[1]/'Tools'))
from package_ipatch import package, read_archive, write_archive
from prepare_rust_patch import apply_prepared, prepare


def variant(name, resource=b'metadata'):
    source = f'patches/{name}/resources/TGExtraRustBridge.plist'
    item = {'name': name, 'bundle_ids': ['ph.telegra.Telegraph'],
            'binary_patches': [{'path': 'Client', 'sha256': hashlib.sha256(name.encode()).hexdigest(),
                                'edits': [{'target': {'type': 'offset', 'offset': 0}, 'expected': '00', 'replacement': '01'}]}],
            'resources': [{'source': source, 'destination': 'TGExtraRustBridge.plist'}]}
    return item, {source: resource}


def client_archive(path, variants):
    sets, files = [], {}
    for item, entries in variants:
        sets.append(item)
        files.update(entries)
    write_archive(path, {'format': 'ipatch', 'version': 1, 'name': 'Client patches', 'patch_sets': sets}, files)


class IpatchPackagingTests(unittest.TestCase):
    def test_each_deb_has_a_self_contained_package_with_all_clients(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            merged = root/'clients.ipatch'
            client_archive(merged, [variant(str(index), str(index).encode()) for index in range(96)])
            for architecture in ('arm', 'arm64', 'arm64e'):
                deb = root/f'com.choco.tg_1.0_iphoneos-{architecture}.deb'
                deb.write_bytes(b'!<arch>\n'+architecture.encode())
                output = deb.with_suffix('.ipatch')
                package(output, deb=deb, merges=[merged])
                entries = read_archive(output)
                manifest = json.loads(entries['manifest.json'])
                self.assertEqual(set(manifest), {'format', 'version', 'name', 'patch_sets'})
                self.assertEqual((manifest['format'], manifest['version']), ('ipatch', 1))
                self.assertEqual(len(manifest['patch_sets']), 96)
                self.assertNotIn('config.json', entries)
                for item in manifest['patch_sets']:
                    self.assertEqual(item['tweaks'], ['tweaks/'+deb.name])
                    self.assertEqual(entries[item['tweaks'][0]], deb.read_bytes())
                    self.assertEqual(item['bundle_ids'], ['ph.telegra.Telegraph'])
                    resource = item['resources'][0]
                    self.assertEqual(entries[resource['source']], item['name'].encode())
                    self.assertEqual(resource['destination'], 'TGExtraRustBridge.plist')
                # Regeneration replaces one client and retains the matching DEB.
                update = root/'update.ipatch'
                client_archive(update, [variant('7', b'updated'), variant('new')])
                package(output, base=output, merges=[update])
                entries = read_archive(output)
                sets = json.loads(entries['manifest.json'])['patch_sets']
                self.assertEqual(len(sets), 97)
                self.assertTrue(all(item['tweaks'] == ['tweaks/'+deb.name] for item in sets))
                self.assertEqual(entries['patches/7/resources/TGExtraRustBridge.plist'], b'updated')
                self.assertEqual(entries['tweaks/'+deb.name], deb.read_bytes())

    def test_committed_patch_sets_use_ipatch_schema(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            deb, output = root/'TGExtra.deb', root/'TGExtra.ipatch'
            deb.write_bytes(b'!<arch>\n')
            package(output, deb=deb, patches=Path(__file__).resolve().parents[1]/'Patches')
            entries = read_archive(output)
            for item in json.loads(entries['manifest.json'])['patch_sets']:
                self.assertEqual(set(item), {'name', 'bundle_ids', 'binary_patches', 'resources', 'tweaks'})
                self.assertTrue(item['name'])
                self.assertTrue(item['bundle_ids'])
                for binary in item['binary_patches']:
                    self.assertEqual(len(binary['sha256']), 64)
                    for edit in binary['edits']:
                        self.assertEqual(set(edit), {'target', 'expected', 'replacement'})
                        self.assertEqual(edit['target']['type'], 'offset')
                        self.assertGreaterEqual(edit['target']['offset'], 0)
                        self.assertEqual(len(bytes.fromhex(edit['expected'])), len(bytes.fromhex(edit['replacement'])))
                for resource in item['resources']:
                    self.assertEqual(plistlib.loads(entries[resource['source']])['ABI'], 5)

    def test_tweak_override_rejection_preserves_output(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            deb, output, client = root/'TGExtra.deb', root/'TGExtra.ipatch', root/'client.ipatch'
            deb.write_bytes(b'!<arch>\n')
            client_archive(client, [variant('original')])
            package(output, deb=deb, merges=[client])
            before = output.read_bytes()
            item, files = variant('bad')
            item['tweaks'] = ['tweaks/another.deb']
            files['tweaks/another.deb'] = b'!<arch>\n'
            client_archive(client, [(item, files)])
            with self.assertRaises(ValueError):
                package(output, base=output, merges=[client])
            self.assertEqual(output.read_bytes(), before)

    def test_generator_exports_native_ipatch_and_repository_set(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            ipa, output, app = root/'Client.ipa', root/'Client.ipatch', root/'Client.app'
            app.mkdir()
            original = b'\xcf\xfa\xed\xfe[MTProtoRust] mt_engine_create failed'
            (app/'Client').write_bytes(original)
            info = {'CFBundleIdentifier': 'app.swiftgram', 'CFBundleName': 'Swiftgram'}
            with zipfile.ZipFile(ipa, 'w') as archive:
                archive.writestr('Payload/Client.app/Info.plist', plistlib.dumps(info))
                archive.writestr('Payload/Client.app/Client', original)
            binary_patch = {'sha256': hashlib.sha256(original).hexdigest(),
                            'edits': [{'offset': 0, 'expected': original[:4].hex(), 'replacement': '00000000'}]}
            paths = root/'paths.txt'
            with mock_patch('prepare_rust_patch.make_patch', return_value=(binary_patch, {'ABI': 5})):
                prepare(ipa, output, export=root/'Patches', apply_app=app, paths_file=paths)
            entries = read_archive(output)
            item = json.loads(entries['manifest.json'])['patch_sets'][0]
            self.assertEqual(item['bundle_ids'], ['app.swiftgram'])
            self.assertEqual(item['binary_patches'][0]['edits'][0]['target'], {'type': 'offset', 'offset': 0})
            self.assertNotIn('tweaks', item)
            self.assertEqual((app/'Client').read_bytes(), b'\0'*4+original[4:])
            self.assertEqual(paths.read_text(), str(app/'Client')+'\n')
            deb = root/'TGExtra.deb'
            deb.write_bytes(b'!<arch>\n')
            package(root/'release.ipatch', deb=deb, patches=root/'Patches')
            released = json.loads(read_archive(root/'release.ipatch')['manifest.json'])['patch_sets'][0]
            self.assertEqual(released['binary_patches'], item['binary_patches'])
            self.assertEqual(released['resources'], item['resources'])

    def test_no_rust_does_not_generate_an_invalid_empty_ipatch(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            ipa, output, paths = root/'Client.ipa', root/'Client.ipatch', root/'paths.txt'
            with zipfile.ZipFile(ipa, 'w') as archive:
                archive.writestr('Payload/Client.app/Info.plist', plistlib.dumps({'CFBundleIdentifier': 'app.client'}))
            output.write_bytes(b'stale archive')
            prepare(ipa, output, paths_file=paths, allow_no_rust=True)
            self.assertFalse(output.exists())
            self.assertEqual(paths.read_text(), '')
            with self.assertRaises(ValueError):
                prepare(ipa, output)

    def test_offline_application_checks_digest_and_preimages(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            binary = root/'Client'
            original = b'original bytes'
            binary.write_bytes(original)
            patch = {'path': 'Client', 'sha256': hashlib.sha256(original).hexdigest(), 'edits': [{'target': {'type': 'offset', 'offset': 0}, 'expected': original[:4].hex(), 'replacement': b'next'.hex()}]}
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
