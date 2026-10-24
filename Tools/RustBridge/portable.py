"""Build declarative ipatch v2 profiles from legacy-reviewed Rust machine code."""
import struct

from macho import signed, page_address


def payload_template(selector, arguments, original, thunk):
    # Generate with distinct temporary addresses, then turn every external
    # instruction fixup into an engine relocation. Local CBZ stays exact.
    start, target = 0x10000, 0x20000
    imports = {'_objc_lookUpClass': 0x30000, '_sel_registerName': 0x40000, '_objc_msgSend': 0x50000}
    names = {target: original, **{address: name for name, address in imports.items()}}
    code = bytearray(thunk(start, target, selector, arguments, imports))
    strings = code.index(b'TGExtraRustBridge\0')
    relocations = []
    for off in range(0, strings, 4):
        word = struct.unpack_from('<I', code, off)[0]
        if word & 0x7C000000 == 0x14000000:
            destination = start+off+signed(word & 0x3FFFFFF, 26)*4
            relocations.append({'type': 'bl' if word >> 31 else 'b', 'offset': off, 'anchor': names[destination]})
            struct.pack_into('<I', code, off, word & 0xFC000000)
        elif word & 0x9F000000 == 0x90000000:
            add = struct.unpack_from('<I', code, off+4)[0]
            destination = page_address(start+off, word)+(add >> 10 & 4095)
            relocation = {'type': 'adrp_add', 'offset': off, 'anchor': original}
            if destination != target:
                relocation.update(anchor='bridge.'+original, addend=destination-start)
            relocations.append(relocation)
            struct.pack_into('<II', code, off, word & 0x9F00001F, add & ~0x3FFC00)
    return bytes(code), relocations


def build_profile(macho, functions, imports, branches, usage, auth_info, constructor, marker_address, *, selectors, thunk):
    anchors, checks, blocks, edits, files = [], [], [], [], {}
    profile = {'arch': 'arm64', 'header_reserve': 65536, 'anchors': anchors,
               'checks': checks, 'blocks': blocks, 'edits': edits}
    # Tiny buffer getters are not unique: validate the cluster surrounding the
    # unique reviewed engine-create body instead of scanning for each getter.
    anchors.append({'name': 'engineCreate', 'type': 'function',
                    'fingerprint': macho.portable_fingerprint(*macho.function(functions['engineCreate']))})
    relatives = {'abi': -1, 'bufferLength': -2, 'bufferFree': -3, 'bufferData': -4, 'nextRequestID': 1}
    for name, address in functions.items():
        if name in ('engineCreate', 'usageManager', 'authInfo'):
            continue
        fingerprint = macho.portable_fingerprint(*macho.function(address))
        if name in relatives:
            anchors.append({'name': name, 'type': 'relative_function', 'from': 'engineCreate', 'index': relatives[name]})
            checks.append({'type': 'function', 'at': name, 'fingerprint': fingerprint})
        else:
            anchors.append({'name': name, 'type': 'function', 'fingerprint': fingerprint})
    # The ABI marker is meaningful data, so retain an exact check as well.
    abi_offset = macho.offset(functions['abi'])
    checks.append({'type': 'bytes', 'at': 'abi', 'expected': macho.data[abi_offset:abi_offset+8].hex()})
    anchors.append({'name': 'sessionInit', 'type': 'function', 'fingerprint': macho.portable_fingerprint(*constructor)})
    section = next((name for name, (address, _, size) in macho.sections.items()
                    if address <= marker_address < address+size), None)
    if section != '__cstring':
        raise ValueError('Rust session marker must be in __TEXT,__cstring')
    anchors.append({'name': 'sessionMarker', 'type': 'pattern', 'target': {
        'type': 'pattern', 'arch': 'arm64', 'segment': '__TEXT', 'section': section,
        'pattern': ' '.join(f'{byte:02X}' for byte in b'[MTProtoRust#0 dc')}})
    references = list(macho.portable_references(marker_address, *constructor))
    if not references:
        raise ValueError('Rust constructor marker has no supported v2 data reference')
    anchors.append({'name': 'sessionMarkerRefs', 'type': 'data_reference', 'to': 'sessionMarker',
                    'within': 'sessionInit', 'window': 6, 'count': len(references)})
    for name, selector in (('usageManager', 'initWithInfo:'), ('authInfo', 'authInfoForDatacenterWithId:selector:')):
        anchors.append({'name': name, 'type': 'objc_stub', 'selector': selector})
    for name in imports:
        if name in ('_objc_lookUpClass', '_sel_registerName', '_objc_msgSend'):
            anchors.append({'name': name, 'type': 'import_stub', 'import': name})
    for name, (selector, arguments) in selectors.items():
        target = functions[name]
        if name in ('usageManager', 'authInfo'):
            sites = [(pc, dest) for pc, dest in branches if constructor[0] <= pc < constructor[1] and dest == target]
        else:
            sites = [(pc, dest) for pc, dest in branches if dest == target]
        if not sites or len(sites) > 512:
            raise ValueError(f'unsupported v2 call count for {name}: {len(sites)}')
        calls = name+'Calls'
        anchor = {'name': calls, 'type': 'calls', 'to': name, 'count': len(sites)}
        if name in ('usageManager', 'authInfo'):
            anchor['within'] = 'sessionInit'
        anchors.append(anchor)
        selected = usage if name == 'usageManager' else auth_info if name == 'authInfo' else sites
        for pc, _ in selected:
            at = calls
            if len(sites) > 1:
                index = sites.index((pc, target))
                at = calls+str(index)
                anchors.append({'name': at, 'type': 'select', 'from': calls, 'index': index})
            instruction = 'bl' if macho.u32(macho.offset(pc)) >> 31 else 'b'
            checks.append({'type': 'branch', 'at': at, 'to': name, 'instruction': instruction})
            if name in ('usageManager', 'authInfo'):
                checks.append({'type': 'within', 'at': at, 'within': 'sessionInit'})
            edits.append({'anchor': at, 'replacement': '00000094' if instruction == 'bl' else '00000014',
                          'relocations': [{'type': instruction, 'offset': 0, 'anchor': 'bridge.'+name}]})
        code, relocations = payload_template(selector, arguments, name, thunk)
        source = 'payloads/'+name+'.bin'
        files[source] = code
        blocks.append({'name': 'bridge.'+name, 'source': source, 'size': len(code), 'alignment': 4,
                       'permissions': 'rx', 'relocations': relocations})
    # The permanent auth query must follow usage/account binding. Additional
    # temporary-key queries are counted but never redirected by this profile.
    usage_edit = next(edit['anchor'] for edit in edits if edit['anchor'].startswith('usageManagerCalls'))
    auth_edit = next(edit['anchor'] for edit in edits if edit['anchor'].startswith('authInfoCalls'))
    checks.append({'type': 'before', 'at': usage_edit, 'to': auth_edit})
    values = {'ABI': {'type': 'uint', 'integer': 5}, 'UUID': {'type': 'uuid'}}
    for key, name in (('BufferData', 'bufferData'), ('BufferLength', 'bufferLength'), ('BufferFree', 'bufferFree'),
                      ('NextRequestID', 'nextRequestID'), ('Send', 'send'), ('Cancel', 'cancel')):
        values[key] = {'type': 'image_offset', 'anchor': name}
    profile['generated_resources'] = [{'destination': 'TGExtraRustBridge.plist', 'arch': 'arm64', 'values': values}]
    return {'search': {'roots': ['.'], 'max_candidates': 128, 'max_bytes': 1 << 30}, 'profile': profile}, files
