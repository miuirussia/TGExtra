#!/usr/bin/env python3
"""Package a DEB with client components, or update an existing ipatch package."""
import argparse
import copy
import json
import os
from pathlib import Path, PurePosixPath
import re
import stat
import tempfile
import zipfile


def relative_path(value):
    path = PurePosixPath(value)
    if not value or path.is_absolute() or '..' in path.parts or str(path) != value or '\\' in value or ':' in value:
        raise ValueError(f'unsafe package path: {value}')
    return path


def read_archive(path):
    with zipfile.ZipFile(path) as archive:
        files = {}
        for entry in archive.infolist():
            if stat.S_ISLNK(entry.external_attr >> 16):
                raise ValueError(f'package cannot contain symlinks: {entry.filename}')
            if entry.is_dir():
                continue
            relative_path(entry.filename)
            if entry.filename in files:
                raise ValueError(f'duplicate archive path: {entry.filename}')
            files[entry.filename] = archive.read(entry)
    return files


def validate_components(value):
    if (value.get('format') != 'ipatch' or value.get('version') != 4 or
            not isinstance(value.get('name'), str) or not value['name'] or
            set(value) - {'format', 'version', 'name', 'components'}):
        raise ValueError('expected an ipatch v4 document')
    components = value.get('components')
    if not isinstance(components, list) or not 1 <= len(components) <= 256:
        raise ValueError('ipatch requires 1–256 components')
    if sum(bool(c.get('optional')) for c in components) > 128:
        raise ValueError('ipatch exceeds 128 optional components')
    def ids(items):
        seen = set()
        for item in items:
            identifier = item.get('id')
            if (not isinstance(identifier, str) or
                    not re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9._-]{0,127}', identifier) or
                    identifier.startswith('ipatch.')):
                raise ValueError(f'invalid ipatch ID: {identifier}')
            if identifier in seen:
                raise ValueError(f'duplicate ipatch ID: {identifier}')
            seen.add(identifier)
    ids(components)
    for component in components:
        if (not component.get('name') or component.get('match') not in ('all_matching', 'exactly_one') or
                not component.get('variants') or
                component.get('default_enabled') and not component.get('optional')):
            raise ValueError('invalid component definition')
        ids(component['variants'])
        for variant in component['variants']:
            if not variant.get('bundle_ids') or not variant.get('binaries'):
                raise ValueError('variant requires bundle_ids and binaries')
            ids(variant['binaries'])
            for binary in variant['binaries']:
                if 'profile' in binary:
                    raise ValueError('v4 binaries cannot contain profile')
                ids([entry for key in ('anchors', 'checks', 'payloads', 'edits')
                     for entry in binary.get(key, [])])


def manifest(files):
    if 'config.json' in files:
        raise ValueError('ipatch cannot also contain config.json')
    value = json.loads(files['manifest.json'])
    validate_components(value)
    return value


def document(name, variants):
    return {'format': 'ipatch', 'version': 4, 'name': name, 'components': [
        {'id': 'required', 'name': 'TGExtra', 'match': 'all_matching', 'variants': variants}]}


def sources(item):
    yield from item.get('resources', [])
    for binary in item['binaries']:
        yield from (payload for payload in binary.get('payloads', []) if 'source' in payload)


def package_source(identifier, source):
    path = relative_path(source)
    if path.parts[0] == 'payloads':
        return f'payloads/{identifier}/'+str(PurePosixPath(*path.parts[1:]))
    return f'patches/{identifier}/{source}'


def repository_components(patches):
    components, files = [], {}
    for directory in sorted(patches.iterdir()):
        if not directory.is_dir():
            continue
        if directory.is_symlink():
            raise ValueError(f'patch resources cannot be symlinks: {directory}')
        value = json.loads((directory/'patch.json').read_text())
        validate_components(value)
        for component in value['components']:
            for item in component['variants']:
                if item.get('tweaks'):
                    raise ValueError('client variants cannot include tweaks')
                for resource in sources(item):
                    source = relative_path(resource['source'])
                    path = directory
                    for part in source.parts:
                        path = path/part
                        if path.is_symlink():
                            raise ValueError(f'patch resources cannot be symlinks: {path}')
                    name = package_source(directory.name, str(source))
                    files[name] = path.read_bytes()
                    if path.suffix == '.bin' and path.with_suffix('.c').exists():
                        companion = path.with_suffix('.c')
                        if companion.is_symlink():
                            raise ValueError(f'patch resources cannot be symlinks: {companion}')
                        files[str(PurePosixPath(name).with_suffix('.c'))] = companion.read_bytes()
                    resource['source'] = name
            components.append(component)
    return components, files


def portable(item):
    return any(binary.get('anchors') for binary in item['binaries'])


def variant_key(item):
    if portable(item):
        compatibility = []
        for binary in item['binaries']:
            proof = {key: value for key, value in binary.items()
                     if key in ('path', 'search', 'sha256', 'arch', 'anchors', 'checks')}
            proof['edit_proofs'] = [{'at': edit['at'], 'expect': edit['expect']}
                                    for edit in binary.get('edits', []) if 'expect' in edit]
            compatibility.append(proof)
        return ('portable', json.dumps(compatibility, sort_keys=True, separators=(',', ':')))
    return (tuple(sorted(item['bundle_ids'])),
            tuple(sorted((binary['path'], binary.get('sha256')) for binary in item['binaries'])))


def write_archive(output, value, files):
    validate_components(value)
    data = (json.dumps(value, separators=(',', ':'))+'\n').encode()
    if len(data) > 1 << 20:
        raise ValueError('ipatch manifest exceeds 1 MiB')
    referenced = {'manifest.json'}
    for component in value['components']:
        for item in component['variants']:
            referenced.update(item.get('tweaks', []))
            referenced.update(resource['source'] for resource in sources(item))
    files = {**files, 'manifest.json': data}
    # Keep reviewable C sources beside live payloads, including through merges.
    # Source companions are optional in imported v4 packages.
    referenced.update(str(PurePosixPath(name).with_suffix('.c')) for name in list(referenced)
                      if name.endswith('.bin') and str(PurePosixPath(name).with_suffix('.c')) in files)
    for name in referenced:
        relative_path(name)
        if name not in files:
            raise ValueError(f'missing package file: {name}')
    output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile(dir=output.parent, delete=False) as temporary:
        staged = Path(temporary.name)
    try:
        with zipfile.ZipFile(staged, 'w', compression=zipfile.ZIP_DEFLATED) as archive:
            for name in sorted(referenced):
                archive.writestr(name, files[name])
        os.replace(staged, output)
    finally:
        staged.unlink(missing_ok=True)


def package(output, deb=None, patches=None, base=None, merges=(), retire_patches=None):
    if (deb is None) == (base is None):
        raise ValueError('provide exactly one of deb or base')
    if base:
        files = read_archive(base)
        value = manifest(files)
        base_variants = [variant for component in value['components'] if not component.get('optional')
                         for variant in component['variants']]
        tweaks = base_variants[0].get('tweaks', []) if base_variants else []
        if any(item.get('tweaks', []) != tweaks for item in base_variants):
            raise ValueError('base package must use the same tweaks in every mandatory variant')
    else:
        data = deb.read_bytes()
        if deb.suffix != '.deb' or not data.startswith(b'!<arch>\n'):
            raise ValueError('expected a Debian archive')
        tweak = 'tweaks/'+deb.name
        tweaks, files = [tweak], {tweak: data}
        value = {'format': 'ipatch', 'version': 4, 'name': 'TGExtra', 'components': []}
    collections = []
    if patches:
        collections.append(repository_components(patches))
    for archive in merges:
        entries = read_archive(archive)
        options = manifest(entries)
        if any(item.get('tweaks') for component in options['components'] for item in component['variants']):
            raise ValueError('merged client packages cannot include tweaks')
        collections.append((options['components'], entries))
    for components, entries in collections:
        for original in components:
            incoming = copy.deepcopy(original)
            target = next((c for c in value['components'] if c['id'] == incoming['id']), None)
            if target is None:
                target = {**incoming, 'variants': []}
                value['components'].append(target)
            metadata = lambda c: {**{k: v for k, v in c.items() if k != 'variants'},
                                  'optional': c.get('optional', False),
                                  'default_enabled': c.get('default_enabled', False)}
            if metadata(target) != metadata(incoming):
                raise ValueError(f'conflicting component definition: {incoming["id"]}')
            for item in incoming['variants']:
                if not target.get('optional'):
                    item['tweaks'] = list(tweaks)
                # Preserve exclusive alternatives by ID. Composable profiles also
                # replace equivalent compatibility proofs and union authorized IDs.
                matches = [old for old in target['variants'] if
                           (variant_key(old) == variant_key(item) if target['match'] == 'all_matching'
                            else old['id'] == item['id'])]
                if portable(item) and target['match'] == 'all_matching':
                    item['bundle_ids'] = sorted(set(item['bundle_ids']).union(*(old['bundle_ids'] for old in matches)))
                target['variants'] = [old for old in target['variants'] if old not in matches]
                target['variants'].append(item)
        files.update({name: data for name, data in entries.items() if name != 'manifest.json'})
    if retire_patches:
        retired, _ = repository_components(retire_patches)
        for component in value['components']:
            if component.get('optional'):
                continue
            portable_ids = {bundle for item in component['variants'] if portable(item) for bundle in item['bundle_ids']}
            keys = {variant_key(item) for c in retired if c['id'] == component['id']
                    for item in c['variants'] if set(item['bundle_ids']) <= portable_ids}
            component['variants'] = [item for item in component['variants'] if variant_key(item) not in keys]
    write_archive(output, value, files)
    count = sum(len(c['variants']) for c in value['components'])
    print(f'Created {output}: ipatch v4, {count} client variants')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    source = parser.add_mutually_exclusive_group(required=True)
    source.add_argument('--deb', type=Path)
    source.add_argument('--base', type=Path)
    parser.add_argument('--output', required=True, type=Path)
    parser.add_argument('--patches', type=Path)
    parser.add_argument('--merge', nargs='*', type=Path, default=[])
    parser.add_argument('--retire-patches', type=Path,
                        help='remove these exact hash-pinned variant identities when packaging portable replacements')
    args = parser.parse_args()
    try:
        package(args.output, args.deb, args.patches, args.base, args.merge, args.retire_patches)
    except (ValueError, KeyError, zipfile.BadZipFile) as error:
        parser.exit(1, f'ipatch packaging: {error}\n')
