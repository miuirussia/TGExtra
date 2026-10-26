#!/usr/bin/env python3
import hashlib
import copy
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


def client_archive(path, variants, version=1, features=None):
    sets, files = [], {}
    for item, entries in variants:
        sets.append(item)
        files.update(entries)
    value = {'format': 'ipatch', 'version': version, 'name': 'Client patches', 'patch_sets': sets}
    if features is not None:
        value['features'] = features
    write_archive(path, value, files)


def portable_variant(name='portable'):
    source = f'payloads/{name}/bridge.bin'
    return {'name': name, 'bundle_ids': ['ph.telegra.Telegraph'], 'binary_patches': [{
        'search': {'roots': ['.'], 'max_candidates': 128, 'max_bytes': 1 << 30},
        'profile': {'arch': 'arm64', 'anchors': [{'name': 'send', 'type': 'symbol', 'target': {
            'type': 'symbol', 'arch': 'arm64', 'name': '_send_'+name}}],
            'blocks': [{'name': 'bridge', 'source': source, 'size': 4, 'alignment': 4, 'permissions': 'rx'}],
            'generated_resources': [{'destination': 'TGExtraRustBridge.plist', 'arch': 'arm64',
                                     'values': {'ABI': {'type': 'uint', 'integer': 5}}}]}}]}, {source: bytes.fromhex('00000014')}


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
            value = json.loads(entries['manifest.json'])
            self.assertEqual(value['version'], 3)
            self.assertEqual([feature['id'] for feature in value['features']], ['swiftgram-pro'])
            self.assertFalse(value['features'][0]['default_enabled'])
            for item in value['patch_sets']:
                self.assertTrue(set(item) <= {'name', 'feature', 'bundle_ids', 'binary_patches', 'resources', 'tweaks'})
                self.assertTrue(item['name'])
                self.assertTrue(item['bundle_ids'])
                if item.get('feature'):
                    self.assertEqual(item['feature'], 'swiftgram-pro')
                    self.assertEqual(item['bundle_ids'], ['app.swiftgram.ios'])
                    self.assertNotIn('tweaks', item)
                else:
                    self.assertEqual(item['tweaks'], ['tweaks/TGExtra.deb'])
                for binary in item['binary_patches']:
                    if 'profile' in binary:
                        self.assertNotIn('sha256', binary)
                        self.assertEqual(binary['profile']['arch'], 'arm64')
                        for block in binary['profile']['blocks']:
                            self.assertTrue(block['source'].startswith('payloads/'))
                            self.assertEqual(len(entries[block['source']]), block['size'])
                        continue
                    self.assertEqual(len(binary['sha256']), 64)
                    for edit in binary['edits']:
                        self.assertEqual(set(edit), {'target', 'expected', 'replacement'})
                        self.assertEqual(edit['target']['type'], 'offset')
                        self.assertGreaterEqual(edit['target']['offset'], 0)
                        self.assertEqual(len(bytes.fromhex(edit['expected'])), len(bytes.fromhex(edit['replacement'])))
                for resource in item.get('resources', []):
                    self.assertEqual(plistlib.loads(entries[resource['source']])['ABI'], 5)

    def test_v3_features_survive_v2_updates_and_keep_base_components_distinct(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            deb, output = root/'TGExtra.deb', root/'TGExtra.ipatch'
            deb.write_bytes(b'!<arch>\n')
            base, files = portable_variant()
            optional = copy.deepcopy(base)
            optional['feature'] = 'pro'
            feature = {'id': 'pro', 'name': 'Pro', 'default_enabled': False}
            client_archive(root/'v3.ipatch', [(base, files), (optional, files)], version=3, features=[feature])
            package(output, deb=deb, merges=[root/'v3.ipatch'])
            client_archive(root/'update.ipatch', [portable_variant('another')], version=2)
            package(output, base=output, merges=[root/'update.ipatch'])
            value = json.loads(read_archive(output)['manifest.json'])
            self.assertEqual(value['version'], 3)
            self.assertEqual(value['features'], [feature])
            self.assertEqual(len(value['patch_sets']), 3)
            self.assertEqual(sum('feature' in item for item in value['patch_sets']), 1)
            self.assertTrue(all(not item.get('tweaks') for item in value['patch_sets'] if item.get('feature')))
            previous = output.read_bytes()
            client_archive(root/'conflict.ipatch', [(optional, files)], version=3,
                           features=[{**feature, 'default_enabled': True}])
            with self.assertRaisesRegex(ValueError, 'conflicting feature'):
                package(output, base=output, merges=[root/'conflict.ipatch'])
            self.assertEqual(output.read_bytes(), previous)

    def test_v3_feature_declarations_cannot_be_missing_or_unused(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            item, files = portable_variant()
            feature = {'id': 'pro', 'name': 'Pro'}
            with self.assertRaisesRegex(ValueError, 'declared and referenced'):
                client_archive(root/'unused.ipatch', [(item, files)], version=3, features=[feature])
            item['feature'] = 'pro'
            with self.assertRaisesRegex(ValueError, 'declared and referenced'):
                client_archive(root/'missing.ipatch', [(item, files)], version=3)
            with self.assertRaisesRegex(ValueError, 'require ipatch v3'):
                client_archive(root/'v2.ipatch', [(item, files)], version=2, features=[feature])

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
                prepare(ipa, output, export=root/'Patches', apply_app=app, paths_file=paths, legacy=True)
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

    def test_v2_generation_exports_payloads_and_matches_repository_packaging(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            ipa, output = root/'Client.ipa', root/'Client.ipatch'
            with zipfile.ZipFile(ipa, 'w') as archive:
                archive.writestr('Payload/Client.app/Info.plist', plistlib.dumps({'CFBundleIdentifier': 'app.swiftgram'}))
                archive.writestr('Payload/Client.app/Client', b'\xcf\xfa\xed\xfe[MTProtoRust] mt_engine_create failed')
            item, files = portable_variant()
            binary = copy.deepcopy(item['binary_patches'][0])
            with mock_patch('prepare_rust_patch.make_portable_patch', return_value=(binary, files)):
                prepare(ipa, output, export=root/'Patches')
            entries = read_archive(output)
            value = json.loads(entries['manifest.json'])
            self.assertEqual(value['version'], 2)
            generated = value['patch_sets'][0]
            self.assertNotIn('resources', generated)
            self.assertEqual(generated['bundle_ids'], ['app.swiftgram'])
            deb = root/'TGExtra.deb'
            deb.write_bytes(b'!<arch>\n')
            package(root/'release.ipatch', deb=deb, patches=root/'Patches')
            released = read_archive(root/'release.ipatch')
            sets = json.loads(released['manifest.json'])['patch_sets']
            self.assertEqual(sets[0]['binary_patches'], generated['binary_patches'])
            for block in binary['profile']['blocks']:
                self.assertEqual(released[block['source']], entries[block['source']])
            other = root/'Other.ipa'
            with zipfile.ZipFile(other, 'w') as archive:
                archive.writestr('Payload/Client.app/Info.plist', plistlib.dumps({'CFBundleIdentifier': 'ph.telegra.Telegraph'}))
                archive.writestr('Payload/Client.app/Client', b'\xcf\xfa\xed\xfe[MTProtoRust] mt_engine_create failed')
            shared, shared_files = portable_variant()
            with mock_patch('prepare_rust_patch.make_portable_patch', return_value=(shared['binary_patches'][0], shared_files)):
                prepare(other, root/'Other.ipatch', export=root/'Patches')
            shared_sets = json.loads(read_archive(root/'Other.ipatch')['manifest.json'])['patch_sets']
            self.assertEqual(shared_sets[0]['bundle_ids'], ['app.swiftgram', 'ph.telegra.Telegraph'])
            self.assertEqual(len(list((root/'Patches').glob('*/patch.json'))), 1)

    def test_mixing_versions_preserves_payloads_and_retires_only_known_legacy(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            deb, output, update = root/'TGExtra.deb', root/'TGExtra.ipatch', root/'update.ipatch'
            deb.write_bytes(b'!<arch>\n')
            client_archive(root/'old.ipatch', [variant('old'), variant('other')])
            package(output, deb=deb, merges=[root/'old.ipatch'])
            old, files = variant('old')
            retired = root/'Legacy'/'old'
            retired.mkdir(parents=True)
            (retired/'patch.json').write_text(json.dumps(old))
            for source, data in files.items():
                path = retired/source
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_bytes(data)
            client_archive(update, [portable_variant()], version=2)
            package(output, base=output, merges=[update], retire_patches=root/'Legacy')
            entries = read_archive(output)
            value = json.loads(entries['manifest.json'])
            self.assertEqual(value['version'], 2)
            self.assertEqual([item['name'] for item in value['patch_sets']], ['other', 'portable'])
            self.assertEqual(entries['payloads/portable/bridge.bin'], bytes.fromhex('00000014'))
            self.assertEqual(entries['tweaks/TGExtra.deb'], deb.read_bytes())
            # Re-merging replaces the same portable profile instead of duplicating it.
            package(output, base=output, merges=[update], retire_patches=root/'Legacy')
            self.assertEqual(len(json.loads(read_archive(output)['manifest.json'])['patch_sets']), 2)

    def test_portable_profile_identity_does_not_collapse_distinct_profiles(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            deb, output = root/'TGExtra.deb', root/'TGExtra.ipatch'
            deb.write_bytes(b'!<arch>\n')
            client_archive(root/'profiles.ipatch', [portable_variant('first'), portable_variant('second')], version=2)
            package(output, deb=deb, merges=[root/'profiles.ipatch'])
            self.assertEqual(len(json.loads(read_archive(output)['manifest.json'])['patch_sets']), 2)

    def test_shared_profile_unions_clients_and_updates_payload_without_duplicates(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            deb, output = root/'TGExtra.deb', root/'TGExtra.ipatch'
            deb.write_bytes(b'!<arch>\n')
            item, files = portable_variant()
            client_archive(root/'first.ipatch', [(item, files)], version=2)
            package(output, deb=deb, merges=[root/'first.ipatch'])
            item['bundle_ids'] = ['app.swiftgram']
            item['binary_patches'][0]['profile']['blocks'][0]['source'] = 'payloads/updated/bridge.bin'
            client_archive(root/'second.ipatch', [(item, {'payloads/updated/bridge.bin': b'next'})], version=2)
            package(output, base=output, merges=[root/'second.ipatch'])
            entries = read_archive(output)
            sets = json.loads(entries['manifest.json'])['patch_sets']
            self.assertEqual(len(sets), 1)
            self.assertEqual(sets[0]['bundle_ids'], ['app.swiftgram', 'ph.telegra.Telegraph'])
            self.assertEqual(entries['payloads/updated/bridge.bin'], b'next')
            self.assertNotIn('payloads/portable/bridge.bin', entries)

    def test_plan_file_cannot_overwrite_input_or_package(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            ipa, output = root/'Client.ipa', root/'Client.ipatch'
            ipa.write_bytes(b'input')
            output.write_bytes(b'package')
            for plan in (ipa, output):
                with self.assertRaisesRegex(ValueError, 'plan file must differ'):
                    prepare(ipa, output, engine=root/'engine', plan_file=plan)
            self.assertEqual(ipa.read_bytes(), b'input')
            self.assertEqual(output.read_bytes(), b'package')

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
