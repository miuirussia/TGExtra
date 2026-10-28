#!/usr/bin/env python3
"""Generate a portable Rust FFI bridge ipatch v4 from a reviewed decrypted IPA."""
import argparse
import base64
import copy
import hashlib
import json
from pathlib import Path
import plistlib
import struct
import sys
import zipfile
import os
import tempfile
import subprocess

sys.path.insert(0, str(Path(__file__).resolve().parent / 'RustBridge'))
from macho import MachO, signed
from package_ipatch import write_archive, sources, package_source, document

PATCH_NAME = 'Rust MTProto Bridge'

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
    """Link the compiled C adapter for the standalone/offline patch path."""
    from portable import payload_template
    from payloads import link_payload
    code, relocations = payload_template(selector, arguments, 'original')
    return link_payload(code, relocations, start,
                        {'original': target, 'bridge.original': start,
                         **{'import.'+name.lstrip('_'): address for name, address in imports.items()}})


def identify(macho, profile):
    specs = profile['functions']
    lengths = {spec['size'] for spec in specs.values()}
    candidates = {name: [] for name in specs}
    for a, b in zip(macho.starts, macho.ends):
        if b-a not in lengths:
            continue
        digest = macho.fingerprint(a, b)
        for name, spec in specs.items():
            reviewed = [spec['sha256']] + [variant['sha256'] for variant in spec.get('variants', [])]
            if spec['size'] == b-a and digest in reviewed:
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


def inspect_runtime(data, profile):
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
    return macho, functions, imports, branches, usage, auth_info, (constructor, end), marker_address


def make_patch(data, profile):
    """Generate verified hash-pinned edits for offline application."""
    macho, functions, imports, branches, usage, auth_info, _, _ = inspect_runtime(data, profile)
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


def make_portable_patch(data, profile):
    from portable import build_profile
    runtime = inspect_runtime(data, profile)
    return build_profile(*runtime, selectors=SELECTORS)


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


def engine_plan(engine, ipa, output, plan_file=None):
    if plan_file and plan_file.resolve() in (ipa.resolve(), output.resolve()):
        raise ValueError('plan file must differ from the input IPA and output package')
    result = subprocess.run([str(engine.resolve()), '-dry-run', '-ipa', str(ipa.resolve()),
                             '-package', str(output.resolve())], capture_output=True, text=True, timeout=180)
    if result.stderr:
        print(result.stderr, end='', file=sys.stderr)
    if plan_file:
        plan_file.write_text(result.stdout)
    report = json.loads(result.stdout)
    if result.returncode or report.get('error'):
        raise ValueError('v4 engine validation failed: '+report.get('error', f'exit {result.returncode}'))
    return report['plan']


def apply_engine_plan(plan, app, expected_path):
    patches = plan.get('patches', [])
    if len(patches) != 1 or patches[0]['path'] != expected_path:
        raise ValueError('unexpected binary in engine plan')
    generated = {'TGExtraRustBridge.plist'}
    if (plan.get('tweaks') or set(plan.get('resources') or {}) - generated or
            set(plan.get('generated_resources', {})) != generated):
        raise ValueError('unexpected resources in bridge engine plan')
    metadata = plistlib.loads(base64.b64decode(plan['generated_resources']['TGExtraRustBridge.plist'], validate=True))
    patch = copy.deepcopy(patches[0])
    for edit in patch['edits']:
        edit['target'] = {'type': 'offset', 'offset': edit.pop('offset')}
    return apply_prepared(patch, metadata, app)


def prepare(ipa, output, export=None, apply_app=None, paths_file=None, allow_no_rust=False,
            legacy=False, engine=None, plan_file=None):
    if ipa.resolve() == output.resolve():
        raise ValueError('output archive must differ from the input IPA')
    if plan_file and not engine:
        raise ValueError('--plan-file requires --engine')
    if plan_file and plan_file.resolve() in (ipa.resolve(), output.resolve()):
        raise ValueError('plan file must differ from the input IPA and output package')
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
            if legacy:
                patch, metadata = make_patch(data, profile)
                patch['path'] = relative
                for edit in patch['edits']:
                    edit['target'] = {'type': 'offset', 'offset': edit.pop('offset')}
                files = {'resources/TGExtraRustBridge.plist': plistlib.dumps(metadata)}
            else:
                patch, files = make_portable_patch(data, profile)
            found.append((patch, files, relative, data))
    if not found and not allow_no_rust:
        raise ValueError('no Rust MTProto runtime: this client uses the existing MtProtoKit hooks')
    if len(found) > 1:
        raise ValueError('multiple Rust runtimes require separate verified account bindings')
    if paths_file:
        paths_file.write_text('')
    if not found:
        output.unlink(missing_ok=True)
        if plan_file:
            plan_file.unlink(missing_ok=True)
        print('No Rust runtime; existing MtProtoKit hooks apply (no ipatch generated)')
        return
    patch, files, binary_path, original = found[0]
    name = PATCH_NAME
    offline_patch = copy.deepcopy(patch) if legacy else None
    if legacy:
        patch = {'id': 'runtime', 'path': patch['path'], 'sha256': patch['sha256'], 'edits': [
            {'id': f'edit-{index+1}', 'at': {'file_offset': edit['target']['offset']},
             'expect': {'bytes': edit['expected']}, 'replace': {'bytes': edit['replacement']}}
            for index, edit in enumerate(patch['edits'])]}
    item = {'bundle_ids': [info['CFBundleIdentifier']], 'binaries': [patch]}
    if legacy:
        identifier = 'rust-'+patch['sha256'][:16]
        item['resources'] = [{'source': 'resources/TGExtraRustBridge.plist', 'destination': 'TGExtraRustBridge.plist'}]
    else:
        identity = {'patch': patch, 'payloads': {source: hashlib.sha256(data).hexdigest()
                                               for source, data in files.items() if source.endswith('.bin')}}
        digest = hashlib.sha256(json.dumps(identity, sort_keys=True, separators=(',', ':')).encode()).hexdigest()
        identifier = 'rust-abi5-'+digest[:16]
    item.update(id=identifier, description=name)
    if export:
        previous_path = export/identifier/'patch.json'
        if not legacy and previous_path.exists():
            previous = json.loads(previous_path.read_text())['components'][0]['variants'][0]
            if previous['binaries'] != item['binaries']:
                raise ValueError('existing profile identity has different binary instructions')
            item['bundle_ids'] = sorted(set(item['bundle_ids']) | set(previous['bundle_ids']))
        for relative, data in {'patch.json': (json.dumps(document(name, [item]), indent=2)+'\n').encode(), **files}.items():
            destination = export/identifier/relative
            destination.parent.mkdir(parents=True, exist_ok=True)
            destination.write_bytes(data)
    for reference in sources(item):
        reference['source'] = package_source(identifier, reference['source'])
    write_archive(output, document(name, [item]),
                  {package_source(identifier, source): data for source, data in files.items()})
    plan = engine_plan(engine, ipa, output, plan_file) if engine else None
    if apply_app:
        if plan and not legacy:
            target = apply_engine_plan(plan, apply_app, binary_path)
        elif legacy:
            target = apply_prepared(offline_patch, plistlib.loads(files['resources/TGExtraRustBridge.plist']), apply_app)
        else:
            # Apply verified edits without a private engine checkout.
            # This applies the same reviewed hooks locally; the release package
            # itself contains portable v4 operations, not these fixed offsets.
            offline, metadata = make_patch(original, profile)
            offline['path'] = binary_path
            for edit in offline['edits']:
                edit['target'] = {'type': 'offset', 'offset': edit.pop('offset')}
            target = apply_prepared(offline, metadata, apply_app)
        if paths_file:
            paths_file.write_text(str(target)+'\n')
    print(f'Created {output}: ipatch v4, {binary_path}')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('ipa', type=Path)
    parser.add_argument('output', type=Path)
    parser.add_argument('--patch-set-dir', type=Path)
    parser.add_argument('--apply-app', type=Path)
    parser.add_argument('--patched-paths-file', type=Path)
    parser.add_argument('--allow-no-rust', action='store_true')
    parser.add_argument('--legacy', action='store_true', help='emit hash-pinned full-file edits in a v4 package')
    parser.add_argument('--engine', type=Path, help='v4 ipatch CLI binary; validate the package and use its plan for --apply-app')
    parser.add_argument('--plan-file', type=Path, help='save the engine dry-run JSON (requires --engine)')
    args = parser.parse_args()
    try:
        prepare(args.ipa, args.output, args.patch_set_dir, args.apply_app, args.patched_paths_file, args.allow_no_rust,
                args.legacy, args.engine, args.plan_file)
    except (ValueError, KeyError, OSError, subprocess.TimeoutExpired, struct.error, zipfile.BadZipFile) as error:
        parser.exit(1, f'Rust bridge: {error}\n')
