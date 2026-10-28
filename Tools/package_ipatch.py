#!/usr/bin/env python3
"""Package a DEB with client patch sets, or update an existing ipatch package."""
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


def manifest(files):
    value = json.loads(files['manifest.json'])
    if value.get('format') != 'ipatch' or value.get('version') not in (1, 2, 3) or not value.get('patch_sets') or 'config.json' in files:
        raise ValueError('expected a version 1, 2 or 3 ipatch with nonempty patch_sets')
    validate_features(value)
    return value


def merge_features(target, definitions):
    if not isinstance(definitions, list):
        raise ValueError('features must be an array')
    seen = set()
    for definition in definitions:
        if not isinstance(definition, dict) or not isinstance(definition.get('id'), str) or not re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9._-]{0,127}', definition['id']):
            raise ValueError('invalid feature definition')
        identifier = definition['id']
        if identifier in seen:
            raise ValueError(f'duplicate feature definition: {identifier}')
        seen.add(identifier)
        normalized = {**definition, 'default_enabled': definition.get('default_enabled', False)}
        if identifier in target and target[identifier] != normalized:
            raise ValueError(f'conflicting feature definition: {identifier}')
        target[identifier] = normalized
    if len(target) > 128:
        raise ValueError('ipatch exceeds 128 features')


def validate_features(value):
    definitions = {}
    merge_features(definitions, value.get('features', []))
    used = {item['feature'] for item in value['patch_sets'] if 'feature' in item}
    if used != definitions.keys():
        raise ValueError('every feature must be declared and referenced by a patch set')
    if ('features' in value or used) and value['version'] < 3:
        raise ValueError('optional features require ipatch v3')


def sources(item):
    yield from item.get('resources', [])
    for binary in item['binary_patches']:
        yield from binary.get('profile', {}).get('blocks', [])


def package_source(identifier, source):
    path = relative_path(source)
    if path.parts[0] == 'payloads':
        return f'payloads/{identifier}/'+str(PurePosixPath(*path.parts[1:]))
    return f'patches/{identifier}/{source}'


def repository_sets(patches):
    sets, files = [], {}
    for directory in sorted(patches.iterdir()):
        if not directory.is_dir():
            continue
        if directory.is_symlink():
            raise ValueError(f'patch resources cannot be symlinks: {directory}')
        item = json.loads((directory/'patch.json').read_text())
        if item.get('tweaks'):
            raise ValueError('client patch sets cannot include tweaks')
        for resource in sources(item):
            source = relative_path(resource['source'])
            path = directory
            for component in source.parts:
                path = path/component
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
        sets.append(item)
    return sets, files


def set_key(item):
    if any('profile' in patch for patch in item['binary_patches']):
        compatibility = copy.deepcopy(item['binary_patches'])
        for patch in compatibility:
            if 'profile' in patch:
                patch['profile'] = {key: value for key, value in patch['profile'].items()
                                    if key in ('arch', 'anchors', 'checks')}
        return ('portable', item.get('feature'), json.dumps(compatibility, sort_keys=True, separators=(',', ':')))
    return (tuple(sorted(item['bundle_ids'])),
            tuple(sorted((patch['path'], patch.get('sha256')) for patch in item['binary_patches'])), item.get('feature'))


def write_archive(output, value, files):
    validate_features(value)
    data = (json.dumps(value, separators=(',', ':'))+'\n').encode()
    if len(data) > 1 << 20:
        raise ValueError('ipatch manifest exceeds 1 MiB')
    referenced = {'manifest.json'}
    for item in value['patch_sets']:
        referenced.update(item.get('tweaks', []))
        referenced.update(resource['source'] for resource in sources(item))
    files = {**files, 'manifest.json': data}
    # Keep reviewable C sources beside live payloads, including through merges.
    # Legacy packages without source companions remain supported.
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
        base_sets = [item for item in value['patch_sets'] if not item.get('feature')]
        tweaks = base_sets[0].get('tweaks', []) if base_sets else []
        if any(item.get('tweaks', []) != tweaks for item in base_sets):
            raise ValueError('base package must use the same tweaks in every base client set')
    else:
        data = deb.read_bytes()
        if deb.suffix != '.deb' or not data.startswith(b'!<arch>\n'):
            raise ValueError('expected a Debian archive')
        tweak = 'tweaks/'+deb.name
        tweaks, files = [tweak], {tweak: data}
        value = {'format': 'ipatch', 'version': 1, 'name': deb.stem, 'patch_sets': []}
    features = {}
    merge_features(features, value.get('features', []))
    collections = []
    if patches:
        collections.append(repository_sets(patches))
        declarations = patches/'features.json'
        if declarations.exists():
            merge_features(features, json.loads(declarations.read_text()))
    for archive in merges:
        entries = read_archive(archive)
        options = manifest(entries)
        merge_features(features, options.get('features', []))
        value['version'] = max(value['version'], options['version'])
        if any(item.get('tweaks') for item in options['patch_sets']):
            raise ValueError('merged client packages cannot include tweaks')
        collections.append((options['patch_sets'], entries))
    for sets, entries in collections:
        for original in sets:
            item = copy.deepcopy(original)
            if not item.get('feature'):
                item['tweaks'] = list(tweaks)
            key = set_key(item)
            if key[0] == 'portable':
                item['bundle_ids'] = sorted(set(item['bundle_ids']).union(
                    *(old['bundle_ids'] for old in value['patch_sets'] if set_key(old) == key)))
            value['patch_sets'] = [old for old in value['patch_sets'] if set_key(old) != key]
            value['patch_sets'].append(item)
        files.update({name: data for name, data in entries.items() if name != 'manifest.json'})
    if any('profile' in patch for item in value['patch_sets'] for patch in item['binary_patches']):
        value['version'] = max(value['version'], 2)
        if retire_patches:
            retired, _ = repository_sets(retire_patches)
            portable_ids = {bundle for item in value['patch_sets']
                            if not item.get('feature') and any('profile' in patch for patch in item['binary_patches']) for bundle in item['bundle_ids']}
            keys = {set_key(item) for item in retired if set(item['bundle_ids']) <= portable_ids}
            value['patch_sets'] = [item for item in value['patch_sets'] if set_key(item) not in keys]
    if not value['patch_sets']:
        raise ValueError('ipatch requires at least one client patch set')
    if features:
        value['features'] = list(features.values())
        value['version'] = 3
    write_archive(output, value, files)
    print(f'Created {output}: {len(value["patch_sets"])} client patch sets')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    source = parser.add_mutually_exclusive_group(required=True)
    source.add_argument('--deb', type=Path)
    source.add_argument('--base', type=Path)
    parser.add_argument('--output', required=True, type=Path)
    parser.add_argument('--patches', type=Path)
    parser.add_argument('--merge', nargs='*', type=Path, default=[])
    parser.add_argument('--retire-patches', type=Path,
                        help='remove these exact legacy set identities when packaging portable replacements')
    args = parser.parse_args()
    try:
        package(args.output, args.deb, args.patches, args.base, args.merge, args.retire_patches)
    except (ValueError, KeyError, zipfile.BadZipFile) as error:
        parser.exit(1, f'ipatch packaging: {error}\n')
