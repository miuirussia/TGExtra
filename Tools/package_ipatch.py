#!/usr/bin/env python3
"""Package a DEB with client patch sets, or update an existing ipatch package."""
import argparse
import copy
import json
import os
from pathlib import Path, PurePosixPath
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
    if value.get('format') != 'ipatch' or value.get('version') != 1 or not value.get('patch_sets') or 'config.json' in files:
        raise ValueError('expected a version 1 ipatch with nonempty patch_sets')
    return value


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
        for resource in item.get('resources', []):
            source = relative_path(resource['source'])
            path = directory
            for component in source.parts:
                path = path/component
                if path.is_symlink():
                    raise ValueError(f'patch resources cannot be symlinks: {path}')
            name = f'patches/{directory.name}/{source}'
            files[name] = path.read_bytes()
            resource['source'] = name
        sets.append(item)
    return sets, files


def set_key(item):
    return (tuple(sorted(item['bundle_ids'])),
            tuple(sorted((patch['path'], patch.get('sha256')) for patch in item['binary_patches'])))


def write_archive(output, value, files):
    data = (json.dumps(value, indent=2)+'\n').encode()
    if len(data) > 1 << 20:
        raise ValueError('ipatch manifest exceeds 1 MiB')
    referenced = {'manifest.json'}
    for item in value['patch_sets']:
        referenced.update(item.get('tweaks', []))
        referenced.update(resource['source'] for resource in item.get('resources', []))
    files = {**files, 'manifest.json': data}
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


def package(output, deb=None, patches=None, base=None, merges=()):
    if (deb is None) == (base is None):
        raise ValueError('provide exactly one of deb or base')
    if base:
        files = read_archive(base)
        value = manifest(files)
        tweaks = value['patch_sets'][0].get('tweaks', [])
        if any(item.get('tweaks', []) != tweaks for item in value['patch_sets']):
            raise ValueError('base package must use the same tweaks in every client set')
    else:
        data = deb.read_bytes()
        if deb.suffix != '.deb' or not data.startswith(b'!<arch>\n'):
            raise ValueError('expected a Debian archive')
        tweak = 'tweaks/'+deb.name
        tweaks, files = [tweak], {tweak: data}
        value = {'format': 'ipatch', 'version': 1, 'name': deb.stem, 'patch_sets': []}
    collections = []
    if patches:
        collections.append(repository_sets(patches))
    for archive in merges:
        entries = read_archive(archive)
        options = manifest(entries)
        if any(item.get('tweaks') for item in options['patch_sets']):
            raise ValueError('merged client packages cannot include tweaks')
        collections.append((options['patch_sets'], entries))
    for sets, entries in collections:
        for original in sets:
            item = copy.deepcopy(original)
            item['tweaks'] = list(tweaks)
            key = set_key(item)
            value['patch_sets'] = [old for old in value['patch_sets'] if set_key(old) != key]
            value['patch_sets'].append(item)
        files.update({name: data for name, data in entries.items() if name != 'manifest.json'})
    if not value['patch_sets']:
        raise ValueError('ipatch requires at least one client patch set')
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
    args = parser.parse_args()
    try:
        package(args.output, args.deb, args.patches, args.base, args.merge)
    except (ValueError, KeyError, zipfile.BadZipFile) as error:
        parser.exit(1, f'ipatch packaging: {error}\n')
