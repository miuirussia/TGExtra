#!/usr/bin/env python3
"""Generate a reviewed Rust FFI bridge .ipatch archive for one decrypted IPA."""
import argparse
import hashlib
import json
from pathlib import Path
import plistlib
import struct
import sys
import zipfile
import os
import tempfile

sys.path.insert(0, str(Path(__file__).resolve().parent / 'RustBridge'))
from macho import MachO, signed
from package_ipatch import write_archive

SELECTORS = {
    'engineCreate': ('engineCreate:context:event:log:original:', 4),
    'sessionCreate': ('sessionCreate:setup:original:', 2),
    'sessionDestroy': ('sessionDestroy:session:original:', 2),
    'send': ('send:session:request:original:', 3),
    'cancel': ('cancel:session:request:original:', 3),
    'bufferData': ('bufferData:original:', 1),
    'bufferLength': ('bufferLength:original:', 1),
    'bufferFree': ('bufferFree:original:', 1),
    'usageManager': ('usageManager:selector:info:original:', 3),
    'authInfo': ('authInfo:selector:datacenter:authSelector:original:', 4),
}


def branch(pc, target, link=False):
    delta = target-pc
    if delta % 4 or not -(1 << 27) <= delta < 1 << 27:
        raise ValueError('arm64 branch is out of range')
    return (0x94000000 if link else 0x14000000) | ((delta//4) & 0x3FFFFFF)


def thunk(start, target, selector, arguments, imports):
    """C arguments -> ObjC class method; fall back to the original if absent."""
    words, relocations = [], []

    def emit(word):
        words.append(word)

    def address(register, name):
        relocations.append((len(words), register, name))
        words.extend([0, 0])

    def call(name):
        emit(branch(start+len(words)*4, imports[name], True))

    emit(0xD10183FF)  # sub sp, sp, #96
    for register in range(0, 8, 2):
        emit(0xA9000000 | ((register//2*16//8) << 15) | ((register+1) << 10) | (31 << 5) | register)
    emit(0xA9047BFD)  # stp x29, x30, [sp,#64]
    address(0, 'class')
    call('_objc_lookUpClass')
    cbz = len(words); emit(0)
    emit(0xF9002BE0)  # str x0, [sp,#80]
    address(0, 'selector')
    call('_sel_registerName')
    emit(0xAA0003E1)  # mov x1, x0
    emit(0xF9402BE0)  # ldr x0, [sp,#80]
    for register in range(arguments):
        emit(0xF9400000 | (register << 10) | (31 << 5) | (register+2))
    address(arguments+2, 'original')
    emit(0xA9447BFD)
    emit(0x910183FF)
    emit(branch(start+len(words)*4, imports['_objc_msgSend']))
    fallback = len(words)
    for register in range(0, 8, 2):
        emit(0xA9400000 | ((register//2*16//8) << 15) | ((register+1) << 10) | (31 << 5) | register)
    emit(0xA9447BFD)
    emit(0x910183FF)
    emit(branch(start+len(words)*4, target))
    words[cbz] = 0xB4000000 | ((fallback-cbz) << 5)
    tail = b'TGExtraRustBridge\0' + selector.encode() + b'\0'
    addresses = {'class': start+len(words)*4, 'selector': start+len(words)*4+18, 'original': target}
    for i, register, name in relocations:
        dest = addresses[name]
        pages = ((dest & ~4095)-((start+i*4) & ~4095))//4096
        if not -(1 << 20) <= pages < 1 << 20:
            raise ValueError('arm64 ADRP out of range')
        pages &= 0x1FFFFF
        words[i] = 0x90000000 | (pages & 3) << 29 | (pages >> 2) << 5 | register
        words[i+1] = 0x91000000 | (dest & 4095) << 10 | register << 5 | register
    result = struct.pack('<'+'I'*len(words), *words)+tail
    return result + b'\0' * (-len(result) % 4)


def identify(macho, profile):
    specs = profile['functions']
    lengths = {spec['size'] for spec in specs.values()}
    candidates = {name: [] for name in specs}
    for a, b in zip(macho.starts, macho.ends):
        if b-a not in lengths:
            continue
        digest = macho.fingerprint(a, b)
        for name, spec in specs.items():
            if spec['size'] == b-a and spec['sha256'] == digest:
                off = macho.offset(a)
                if 'exact' not in spec or macho.data[off:off+b-a].hex() == spec['exact']:
                    candidates[name].append(a)
    # The three buffer routines immediately precede ABI version and engine create.
    creates = candidates['engineCreate']
    if len(creates) != 1:
        raise ValueError('unrecognized or ambiguous Rust engine_create implementation')
    i = macho.starts.index(creates[0])
    for distance, name in enumerate(('abi', 'bufferLength', 'bufferFree', 'bufferData'), 1):
        address = macho.starts[i-distance]
        if address not in candidates[name]:
            raise ValueError(f'unrecognized Rust ABI/buffer cluster: {name}')
        candidates[name] = [address]
    if 'nextRequestID' in candidates:
        address = macho.starts[i+1]
        if address not in candidates['nextRequestID']:
            raise ValueError('unrecognized Rust request-ID allocator')
        candidates['nextRequestID'] = [address]
    result = {}
    for name, addresses in candidates.items():
        if len(addresses) != 1:
            raise ValueError(f'unrecognized or ambiguous Rust function: {name} ({len(addresses)} matches)')
        result[name] = addresses[0]
    return result


def make_patch(data, profile):
    macho = MachO(data)
    functions = identify(macho, profile)
    imports = macho.imports()
    for name in ('_objc_lookUpClass', '_sel_registerName', '_objc_msgSend'):
        if name not in imports:
            raise ValueError(f'missing Objective-C import {name}')
    marker = b'[MTProtoRust#0 dc'
    string = data.find(marker)
    if string < 0 or data.find(marker, string+1) >= 0:
        raise ValueError('missing/ambiguous Rust session initializer marker')
    # Convert the marker file offset to its mapped address.
    marker_address = next(vm+string-off for _, vm, off, size in macho.segments if off <= string < off+size)
    constructors = {macho.function(ref) for ref in macho.references(marker_address)}
    if len(constructors) != 1:
        raise ValueError('unrecognized Rust session initializer')
    constructor, end = constructors.pop()
    branches = list(macho.branches())
    usage = [(pc, target) for pc, target in branches if constructor <= pc < end and macho.objc_stub(target, 'initWithInfo:')]
    if len(usage) != 1:
        raise ValueError('unrecognized Rust session account binding')
    functions['usageManager'] = usage[0][1]
    auth_info = [(pc, target) for pc, target in branches if usage[0][0] < pc < end and
                 macho.objc_stub(target, 'authInfoForDatacenterWithId:selector:')]
    if not auth_info:
        raise ValueError('unrecognized Rust session context binding')
    # The first query is the initializer's permanent key lookup. Later queries
    # can be inlined temporary-key probes; only bind the always-executed one.
    auth_info = auth_info[:1]
    functions['authInfo'] = auth_info[0][1]
    # Keep substantial load-command growth room; the code lives in executable
    # __TEXT header padding. Existing sections/segments never move or grow.
    cave_offset = (macho.command_end+0xFFFF) & ~0xFFFF
    if cave_offset+4096 > macho.textoff or any(data[cave_offset:cave_offset+4096]):
        raise ValueError('insufficient zero executable header padding')
    text_segment = next(s for s in macho.segments if s[0] == '__TEXT' and s[2] == 0)
    cave_address = text_segment[1]+cave_offset
    edits, code = [], bytearray()
    for name, (selector, count) in SELECTORS.items():
        target = functions[name]
        sites = usage if name == 'usageManager' else auth_info if name == 'authInfo' else [(pc, dest) for pc, dest in branches if dest == target]
        if not sites:
            raise ValueError(f'Rust function has no call sites: {name}')
        address = cave_address+len(code)
        code += thunk(address, target, selector, count, imports)
        for pc, _ in sites:
            off = macho.offset(pc)
            word = macho.u32(off)
            replacement = struct.pack('<I', branch(pc, address, bool(word & 0x80000000)))
            edits.append({'offset': off, 'expected': data[off:off+4].hex(), 'replacement': replacement.hex()})
    if len(code) > 4096:
        raise ValueError('Rust thunks exceeded reserved padding')
    edits.append({'offset': cave_offset, 'expected': bytes(len(code)).hex(), 'replacement': code.hex()})
    edits.sort(key=lambda edit: edit['offset'])
    metadata = {'ABI': 5, 'UUID': macho.uuid,
                'BufferData': functions['bufferData']-text_segment[1],
                'BufferLength': functions['bufferLength']-text_segment[1],
                'BufferFree': functions['bufferFree']-text_segment[1],
                'NextRequestID': functions['nextRequestID']-text_segment[1],
                'Send': functions['send']-text_segment[1],
                'Cancel': functions['cancel']-text_segment[1]}
    return {'sha256': hashlib.sha256(data).hexdigest(), 'edits': edits}, metadata


def apply_prepared(patch, metadata, app):
    relative = Path(patch['path'])
    if relative.is_absolute() or '..' in relative.parts:
        raise ValueError('unsafe target path')
    target = app
    for component in relative.parts:
        target = target/component
        if target.is_symlink():
            raise ValueError('target path contains a symbolic link')
    data = bytearray(target.read_bytes())
    if hashlib.sha256(data).hexdigest() != patch['sha256']:
        raise ValueError('extracted binary differs from input IPA')
    for edit in patch['edits']:
        expected = bytes.fromhex(edit['expected'])
        offset = edit['target']['offset']
        if data[offset:offset+len(expected)] != expected:
            raise ValueError(f'patch preimage mismatch at {offset:#x}')
    for edit in patch['edits']:
        replacement = bytes.fromhex(edit['replacement'])
        offset = edit['target']['offset']
        data[offset:offset+len(replacement)] = replacement
    with tempfile.NamedTemporaryFile(dir=target.parent, delete=False) as temporary:
        temporary.write(data)
        staged = Path(temporary.name)
    try:
        staged.chmod(target.stat().st_mode & 0o777)
        os.replace(staged, target)
    finally:
        staged.unlink(missing_ok=True)
    (app/'TGExtraRustBridge.plist').write_bytes(plistlib.dumps(metadata))
    return target


def prepare(ipa, output, export=None, apply_app=None, paths_file=None, allow_no_rust=False):
    if ipa.resolve() == output.resolve():
        raise ValueError('output archive must differ from the input IPA')
    profile = json.loads((Path(__file__).parent/'RustBridge/abi5.json').read_text())
    found = []
    with zipfile.ZipFile(ipa) as archive:
        apps = [name.rsplit('/', 1)[0] for name in archive.namelist() if name.startswith('Payload/') and name.count('/') == 2 and name.endswith('/Info.plist')]
        if len(apps) != 1:
            raise ValueError('expected one top-level application')
        root = apps[0]+'/'
        info = plistlib.loads(archive.read(root+'Info.plist'))
        for entry in archive.infolist():
            if entry.is_dir() or not entry.filename.startswith(root) or entry.file_size > 256 << 20:
                continue
            relative = entry.filename[len(root):]
            if '.' in relative.rsplit('/', 1)[-1] and not relative.endswith('.dylib'):
                continue
            with archive.open(entry) as source:
                magic = source.read(4)
            if magic not in (b'\xcf\xfa\xed\xfe', b'\xca\xfe\xba\xbe'):
                continue
            data = archive.read(entry)
            if b'[MTProtoRust] mt_engine_create failed' not in data:
                continue
            patch, metadata = make_patch(data, profile)
            patch['path'] = relative
            for edit in patch['edits']:
                edit['target'] = {'type': 'offset', 'offset': edit.pop('offset')}
            found.append((patch, metadata))
    if not found and not allow_no_rust:
        raise ValueError('no Rust MTProto runtime: this client uses the existing MtProtoKit hooks')
    if len(found) > 1:
        raise ValueError('multiple Rust runtimes require separate verified account bindings')
    if paths_file:
        paths_file.write_text('')
    if not found:
        output.unlink(missing_ok=True)
        print('No Rust runtime; existing MtProtoKit hooks apply (no ipatch generated)')
        return
    patch, metadata = found[0]
    name = f"{info.get('CFBundleDisplayName', info.get('CFBundleName', 'Client'))} {info.get('CFBundleShortVersionString', '')} ({info.get('CFBundleVersion', '')})"
    resource = 'resources/TGExtraRustBridge.plist'
    item = {'name': name, 'bundle_ids': [info['CFBundleIdentifier']], 'binary_patches': [patch],
            'resources': [{'source': resource, 'destination': 'TGExtraRustBridge.plist'}]}
    prefix = 'patches/rust-'+patch['sha256'][:16]+'/'
    if export:
        for relative, data in {'patch.json': (json.dumps(item, indent=2)+'\n').encode(), resource: plistlib.dumps(metadata)}.items():
            destination = export/('rust-'+patch['sha256'][:16])/relative
            destination.parent.mkdir(parents=True, exist_ok=True)
            destination.write_bytes(data)
    item['resources'][0]['source'] = prefix+resource
    write_archive(output, {'format': 'ipatch', 'version': 1, 'name': name, 'patch_sets': [item]},
                  {prefix+resource: plistlib.dumps(metadata)})
    if apply_app:
        target = apply_prepared(patch, metadata, apply_app)
        if paths_file:
            paths_file.write_text(str(target)+'\n')
    print(f'Created {output}: {patch["path"]}, {len(patch["edits"])-1} call sites')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('ipa', type=Path)
    parser.add_argument('output', type=Path)
    parser.add_argument('--patch-set-dir', type=Path)
    parser.add_argument('--apply-app', type=Path)
    parser.add_argument('--patched-paths-file', type=Path)
    parser.add_argument('--allow-no-rust', action='store_true')
    args = parser.parse_args()
    try:
        prepare(args.ipa, args.output, args.patch_set_dir, args.apply_app, args.patched_paths_file, args.allow_no_rust)
    except (ValueError, KeyError, struct.error, zipfile.BadZipFile) as error:
        parser.exit(1, f'Rust bridge: {error}\n')
