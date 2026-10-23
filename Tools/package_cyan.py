#!/usr/bin/env python3
"""Add client-specific patch sets to a base cyan, or merge generated patch cyans."""
import argparse
import json
from pathlib import Path, PurePosixPath
import tempfile
import os
import zipfile


def read_archive(path, with_info=False):
    with zipfile.ZipFile(path) as archive:
        files, infos = {}, {}
        for entry in archive.infolist():
            if entry.is_dir():
                continue
            name = PurePosixPath(entry.filename)
            if name.is_absolute() or '..' in name.parts or str(name) != entry.filename or '\\' in entry.filename:
                raise ValueError(f'unsafe archive path: {entry.filename}')
            if entry.filename in files:
                raise ValueError(f'duplicate archive path: {entry.filename}')
            files[entry.filename] = archive.read(entry)
            infos[entry.filename] = entry
    return (files, infos) if with_info else files


def patch_sets(files):
    groups = {}
    for name, data in files.items():
        parts = PurePosixPath(name).parts
        if len(parts) >= 3 and parts[0] == 'patches':
            prefix = '/'.join(parts[:2])+'/'
            groups.setdefault(prefix, {})[name] = data
    for prefix, entries in groups.items():
        manifest = json.loads(entries[prefix+'patch.json'])
        if not manifest.get('binary_patches'):
            raise ValueError(f'patch set has no binary_patches: {prefix}')
    return groups


def package(base, output, patches=None, merges=()):
    files, infos = read_archive(base, with_info=True)
    config = json.loads(files['config.json'])
    collections = []
    if patches:
        entries = {}
        for path in sorted(patches.rglob('*')):
            if path.is_symlink():
                raise ValueError(f'patch resources cannot be symlinks: {path}')
            if path.is_file():
                entries['patches/'+path.relative_to(patches).as_posix()] = path.read_bytes()
        collections.append((entries, {}))
    for archive in merges:
        entries, entry_infos = read_archive(archive, with_info=True)
        options = json.loads(entries['config.json'])
        if set(options)-{'patch_sets'}:
            raise ValueError('merged patch archives may only configure patch_sets')
        collections.append((entries, entry_infos))
    for collection, entry_infos in collections:
        for prefix, entries in patch_sets(collection).items():
            # A regenerated variant replaces the whole prior set, including
            # resources; global tweak files and other client variants survive.
            files = {name: data for name, data in files.items() if not name.startswith(prefix)}
            files.update(entries)
            infos = {name: info for name, info in infos.items() if not name.startswith(prefix)}
            infos.update({name: entry_infos[name] for name in entries if name in entry_infos})
    count = len(patch_sets(files))
    if count:
        config['patch_sets'] = True
    files['config.json'] = (json.dumps(config, indent=2)+'\n').encode()
    output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile(dir=output.parent, delete=False) as temporary:
        staged = Path(temporary.name)
    try:
        with zipfile.ZipFile(staged, 'w', compression=zipfile.ZIP_DEFLATED) as archive:
            for name, data in sorted(files.items()):
                archive.writestr(infos.get(name, name), data)
        os.replace(staged, output)
    finally:
        staged.unlink(missing_ok=True)
    print(f'Created {output}: {count} client patch sets')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--base', required=True, type=Path)
    parser.add_argument('--output', required=True, type=Path)
    parser.add_argument('--patches', type=Path)
    parser.add_argument('--merge', nargs='*', type=Path, default=[])
    args = parser.parse_args()
    try:
        package(args.base, args.output, args.patches, args.merge)
    except (ValueError, KeyError, zipfile.BadZipFile) as error:
        parser.exit(1, f'Cyan packaging: {error}\n')
