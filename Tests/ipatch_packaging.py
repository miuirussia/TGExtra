#!/usr/bin/env python3
import hashlib
import copy
import json
import os
from pathlib import Path
import plistlib
import sys
import subprocess
import tempfile
import unittest
from unittest.mock import patch as mock_patch
import zipfile
sys.path.insert(0, str(Path(__file__).resolve().parents[1]/'Tools'))
from package_ipatch import package, read_archive, write_archive, document
from prepare_rust_patch import apply_prepared, prepare


def variants(value):
    return [variant for component in value['components'] for variant in component['variants']]


def variant(name, resource=b'metadata'):
    source = f'patches/{name}/resources/TGExtraRustBridge.plist'
    item = {'id': name, 'bundle_ids': ['ph.telegra.Telegraph'],
            'binaries': [{'id': 'runtime', 'path': 'Client', 'sha256': hashlib.sha256(name.encode()).hexdigest(),
                          'edits': [{'id': 'change', 'at': {'file_offset': 0},
                                     'expect': {'bytes': '00'}, 'replace': {'bytes': '01'}}]}],
            'resources': [{'source': source, 'destination': 'TGExtraRustBridge.plist'}]}
    return item, {source: resource}


def client_archive(path, items, optional=None):
    files = {name: data for _, entries in items for name, data in entries.items()}
    value = document('Client patches', [item for item, _ in items])
    if optional:
        value['components'].append({**optional, 'optional': True, 'match': 'all_matching',
                                    'variants': [copy.deepcopy(items[0][0])]})
    write_archive(path, value, files)


def portable_variant(name='portable'):
    source = f'payloads/{name}/bridge.bin'
    return {'id': name, 'bundle_ids': ['ph.telegra.Telegraph'], 'binaries': [{
        'id': 'runtime', 'search': {'roots': ['.'], 'max_candidates': 128, 'max_bytes': 1 << 30},
        'arch': 'arm64', 'anchors': [{'id': 'send', 'find': {'symbol': {'name': '_send_'+name}}}],
        'payloads': [{'id': 'bridge', 'source': source, 'size': 4, 'alignment': 4, 'permissions': 'rx'}],
        'generated_resources': [{'destination': 'TGExtraRustBridge.plist', 'arch': 'arm64',
                                 'values': {'ABI': {'type': 'uint', 'integer': 5}}}]}]}, {source: bytes.fromhex('00000014')}


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
                self.assertEqual(set(manifest), {'format', 'version', 'name', 'components'})
                self.assertEqual((manifest['format'], manifest['version']), ('ipatch', 4))
                self.assertEqual(len(variants(manifest)), 96)
                self.assertNotIn('config.json', entries)
                for item in variants(manifest):
                    self.assertEqual(item['tweaks'], ['tweaks/'+deb.name])
                    self.assertEqual(entries[item['tweaks'][0]], deb.read_bytes())
                    self.assertEqual(item['bundle_ids'], ['ph.telegra.Telegraph'])
                    resource = item['resources'][0]
                    self.assertEqual(entries[resource['source']], item['id'].encode())
                    self.assertEqual(resource['destination'], 'TGExtraRustBridge.plist')
                # Regeneration replaces one client and retains the matching DEB.
                update = root/'update.ipatch'
                client_archive(update, [variant('7', b'updated'), variant('new')])
                package(output, base=output, merges=[update])
                entries = read_archive(output)
                sets = variants(json.loads(entries['manifest.json']))
                self.assertEqual(len(sets), 97)
                self.assertTrue(all(item['tweaks'] == ['tweaks/'+deb.name] for item in sets))
                self.assertEqual(entries['patches/7/resources/TGExtraRustBridge.plist'], b'updated')
                self.assertEqual(entries['tweaks/'+deb.name], deb.read_bytes())

    def test_committed_documents_use_v4_components(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            deb, output = root/'TGExtra.deb', root/'TGExtra.ipatch'
            deb.write_bytes(b'!<arch>\n')
            package(output, deb=deb, patches=Path(__file__).resolve().parents[1]/'Patches')
            entries = read_archive(output)
            value = json.loads(entries['manifest.json'])
            self.assertEqual(value['version'], 4)
            self.assertEqual({c['id'] for c in value['components']}, {'required', 'swiftgram-pro'})
            for component in value['components']:
                self.assertEqual(component['match'], 'all_matching')
                optional = component.get('optional', False)
                self.assertFalse(component.get('default_enabled', False))
                for item in component['variants']:
                    self.assertEqual(item.get('tweaks', []), [] if optional else ['tweaks/TGExtra.deb'])
                    self.assertTrue(item['bundle_ids'])
                    for binary in item['binaries']:
                        self.assertNotIn('profile', binary)
                        self.assertEqual(binary['arch'], 'arm64')
                        ids = [entry['id'] for key in ('anchors', 'checks', 'edits', 'payloads')
                               for entry in binary.get(key, [])]
                        self.assertEqual(len(ids), len(set(ids)))
                        for payload in binary['payloads']:
                            self.assertTrue(payload['source'].startswith('payloads/'))
                            self.assertEqual(len(entries[payload['source']]), payload['size'])
                            self.assertIn(str(Path(payload['source']).with_suffix('.c')), entries)

    def test_optional_components_survive_updates_and_keep_base_distinct(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            deb, output = root/'TGExtra.deb', root/'TGExtra.ipatch'
            deb.write_bytes(b'!<arch>\n')
            feature = {'id': 'pro', 'name': 'Pro', 'default_enabled': False}
            client_archive(root/'clients.ipatch', [portable_variant()], optional=feature)
            package(output, deb=deb, merges=[root/'clients.ipatch'])
            client_archive(root/'update.ipatch', [portable_variant('another')])
            package(output, base=output, merges=[root/'update.ipatch'])
            value = json.loads(read_archive(output)['manifest.json'])
            self.assertEqual(value['version'], 4)
            self.assertEqual(len(variants(value)), 3)
            optional, = [c for c in value['components'] if c.get('optional')]
            self.assertEqual(optional['id'], 'pro')
            self.assertFalse(optional['default_enabled'])
            self.assertTrue(all(not item.get('tweaks') for item in optional['variants']))
            previous = output.read_bytes()
            client_archive(root/'conflict.ipatch', [portable_variant()],
                           optional={**feature, 'default_enabled': True})
            with self.assertRaisesRegex(ValueError, 'conflicting component'):
                package(output, base=output, merges=[root/'conflict.ipatch'])
            self.assertEqual(output.read_bytes(), previous)

    def test_legacy_documents_and_duplicate_ids_are_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            item, files = portable_variant()
            value = document('Clients', [item])
            for version in (1, 2, 3):
                with self.assertRaisesRegex(ValueError, 'v4'):
                    write_archive(root/'old.ipatch', {**value, 'version': version}, files)
            value['components'][0]['variants'].append(copy.deepcopy(item))
            with self.assertRaisesRegex(ValueError, 'duplicate ipatch ID'):
                write_archive(root/'duplicate.ipatch', value, files)

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
            item = variants(json.loads(entries['manifest.json']))[0]
            self.assertEqual(item['bundle_ids'], ['app.swiftgram'])
            self.assertEqual(item['binaries'][0]['edits'][0]['at'], {'file_offset': 0})
            self.assertNotIn('tweaks', item)
            self.assertEqual((app/'Client').read_bytes(), b'\0'*4+original[4:])
            self.assertEqual(paths.read_text(), str(app/'Client')+'\n')
            deb = root/'TGExtra.deb'
            deb.write_bytes(b'!<arch>\n')
            package(root/'release.ipatch', deb=deb, patches=root/'Patches')
            released = variants(json.loads(read_archive(root/'release.ipatch')['manifest.json']))[0]
            self.assertEqual(released['binaries'], item['binaries'])
            self.assertEqual(released['resources'], item['resources'])

    def test_v4_generation_exports_payloads_and_matches_repository_packaging(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            ipa, output = root/'Client.ipa', root/'Client.ipatch'
            with zipfile.ZipFile(ipa, 'w') as archive:
                archive.writestr('Payload/Client.app/Info.plist', plistlib.dumps({'CFBundleIdentifier': 'app.swiftgram'}))
                archive.writestr('Payload/Client.app/Client', b'\xcf\xfa\xed\xfe[MTProtoRust] mt_engine_create failed')
            item, files = portable_variant()
            binary = copy.deepcopy(item['binaries'][0])
            with mock_patch('prepare_rust_patch.make_portable_patch', return_value=(binary, files)):
                prepare(ipa, output, export=root/'Patches')
            entries = read_archive(output)
            value = json.loads(entries['manifest.json'])
            self.assertEqual(value['version'], 4)
            generated = variants(value)[0]
            self.assertNotIn('resources', generated)
            self.assertEqual(generated['bundle_ids'], ['app.swiftgram'])
            deb = root/'TGExtra.deb'
            deb.write_bytes(b'!<arch>\n')
            package(root/'release.ipatch', deb=deb, patches=root/'Patches')
            released = read_archive(root/'release.ipatch')
            sets = variants(json.loads(released['manifest.json']))
            self.assertEqual(sets[0]['binaries'], generated['binaries'])
            for block in binary['payloads']:
                self.assertEqual(released[block['source']], entries[block['source']])
            other = root/'Other.ipa'
            with zipfile.ZipFile(other, 'w') as archive:
                archive.writestr('Payload/Client.app/Info.plist', plistlib.dumps({'CFBundleIdentifier': 'ph.telegra.Telegraph'}))
                archive.writestr('Payload/Client.app/Client', b'\xcf\xfa\xed\xfe[MTProtoRust] mt_engine_create failed')
            shared, shared_files = portable_variant()
            with mock_patch('prepare_rust_patch.make_portable_patch', return_value=(shared['binaries'][0], shared_files)):
                prepare(other, root/'Other.ipatch', export=root/'Patches')
            shared_sets = variants(json.loads(read_archive(root/'Other.ipatch')['manifest.json']))
            self.assertEqual(shared_sets[0]['bundle_ids'], ['app.swiftgram', 'ph.telegra.Telegraph'])
            self.assertEqual(len(list((root/'Patches').glob('*/patch.json'))), 1)

    def test_merging_variants_preserves_payloads_and_retires_only_known_legacy(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            deb, output, update = root/'TGExtra.deb', root/'TGExtra.ipatch', root/'update.ipatch'
            deb.write_bytes(b'!<arch>\n')
            client_archive(root/'old.ipatch', [variant('old'), variant('other')])
            package(output, deb=deb, merges=[root/'old.ipatch'])
            old, files = variant('old')
            retired = root/'Legacy'/'old'
            retired.mkdir(parents=True)
            (retired/'patch.json').write_text(json.dumps(document('Client patches', [old])))
            for source, data in files.items():
                path = retired/source
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_bytes(data)
            client_archive(update, [portable_variant()])
            package(output, base=output, merges=[update], retire_patches=root/'Legacy')
            entries = read_archive(output)
            value = json.loads(entries['manifest.json'])
            self.assertEqual(value['version'], 4)
            self.assertEqual([item['id'] for item in variants(value)], ['other', 'portable'])
            self.assertEqual(entries['payloads/portable/bridge.bin'], bytes.fromhex('00000014'))
            self.assertEqual(entries['tweaks/TGExtra.deb'], deb.read_bytes())
            # Re-merging replaces the same portable profile instead of duplicating it.
            package(output, base=output, merges=[update], retire_patches=root/'Legacy')
            self.assertEqual(len(variants(json.loads(read_archive(output)['manifest.json']))), 2)

    def test_portable_profile_identity_does_not_collapse_distinct_profiles(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            deb, output = root/'TGExtra.deb', root/'TGExtra.ipatch'
            deb.write_bytes(b'!<arch>\n')
            client_archive(root/'profiles.ipatch', [portable_variant('first'), portable_variant('second')])
            package(output, deb=deb, merges=[root/'profiles.ipatch'])
            self.assertEqual(len(variants(json.loads(read_archive(output)['manifest.json']))), 2)

    def test_shared_profile_unions_clients_and_updates_payload_without_duplicates(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            deb, output = root/'TGExtra.deb', root/'TGExtra.ipatch'
            deb.write_bytes(b'!<arch>\n')
            item, files = portable_variant()
            client_archive(root/'first.ipatch', [(item, files)])
            package(output, deb=deb, merges=[root/'first.ipatch'])
            item['bundle_ids'] = ['app.swiftgram']
            item['binaries'][0]['payloads'][0]['source'] = 'payloads/updated/bridge.bin'
            client_archive(root/'second.ipatch', [(item, {'payloads/updated/bridge.bin': b'next'})])
            package(output, base=output, merges=[root/'second.ipatch'])
            entries = read_archive(output)
            sets = variants(json.loads(entries['manifest.json']))
            self.assertEqual(len(sets), 1)
            self.assertEqual(sets[0]['bundle_ids'], ['app.swiftgram', 'ph.telegra.Telegraph'])
            self.assertEqual(entries['payloads/updated/bridge.bin'], b'next')
            self.assertNotIn('payloads/portable/bridge.bin', entries)

    def test_exclusive_variants_keep_their_policy_and_update_by_id(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            deb, output = root/'TGExtra.deb', root/'TGExtra.ipatch'
            deb.write_bytes(b'!<arch>\n')
            first, files = portable_variant()
            second = {**copy.deepcopy(first), 'id': 'alternative'}
            value = document('Clients', [first, second])
            value['components'][0]['match'] = 'exactly_one'
            write_archive(root/'clients.ipatch', value, files)
            package(output, deb=deb, merges=[root/'clients.ipatch'])
            value['components'][0]['variants'] = [second]
            write_archive(root/'update.ipatch', value, files)
            package(output, base=output, merges=[root/'update.ipatch'])
            result = json.loads(read_archive(output)['manifest.json'])
            self.assertEqual(result['components'][0]['match'], 'exactly_one')
            self.assertEqual([v['id'] for v in variants(result)], ['portable', 'alternative'])

    def test_portable_variants_keep_distinct_exact_preimages(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            deb = root/'TGExtra.deb'
            deb.write_bytes(b'!<arch>\n')
            first, files = portable_variant()
            first['binaries'][0]['edits'] = [{'id': 'change', 'at': {'anchor': 'send'},
                'expect': {'bytes': '00000000'}, 'replace': {'bytes': '00000014'}}]
            second = copy.deepcopy(first)
            second['id'] = 'alternative'
            second['binaries'][0]['edits'][0]['expect']['bytes'] = '01000000'
            client_archive(root/'clients.ipatch', [(first, files), (second, files)])
            package(root/'output.ipatch', deb=deb, merges=[root/'clients.ipatch'])
            self.assertEqual(len(variants(json.loads(read_archive(root/'output.ipatch')['manifest.json']))), 2)

    @unittest.skipUnless(os.environ.get('IPATCH_ENGINE_CLI'), 'requires the real iPatch v4 engine CLI')
    def test_engine_checks_and_packs_all_sources_and_release_manifest(self):
        patches = Path(__file__).resolve().parents[1]/'Patches'
        engine = os.environ['IPATCH_ENGINE_CLI']
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            for source in sorted(patches.glob('*/patch.json')):
                with self.subTest(source=source.parent.name):
                    subprocess.run([engine, '-check', str(source)], check=True, capture_output=True)
                    subprocess.run([engine, '-pack', str(source), '-output', str(root/(source.parent.name+'.ipatch'))],
                                   check=True, capture_output=True)
            deb, output = root/'TGExtra.deb', root/'TGExtra.ipatch'
            deb.write_bytes(b'!<arch>\n')
            package(output, deb=deb, patches=patches)
            source = root/'manifest.json'
            source.write_bytes(read_archive(output)['manifest.json'])
            subprocess.run([engine, '-check', str(source)], check=True, capture_output=True)

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
