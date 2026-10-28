"""Build declarative ipatch v2 profiles from legacy-reviewed Rust machine code."""
import json

from payloads import ipatch_payload


def payload_source(selector, arguments, name):
    """Emit a standalone, readable C source beside each exported binary."""
    names = {
        'engineCreate': ('threads', 'context', 'event', 'log'),
        'sessionCreate': ('engine', 'setup'),
        'sessionDestroy': ('engine', 'session'),
        'send': ('engine', 'session', 'request'),
        'cancel': ('engine', 'session', 'request'),
        'bufferData': ('buffer',), 'bufferLength': ('buffer',), 'bufferFree': ('buffer',),
        'usageManager': ('receiver', 'selector', 'info'),
        'authInfo': ('receiver', 'selector', 'datacenter', 'authSelector'),
    }.get(name, ('a', 'b', 'c', 'd')[:arguments])
    if len(names) != arguments or not 1 <= arguments <= 4:
        raise ValueError('unsupported Rust bridge argument count')
    parameters = ', '.join('uintptr_t '+arg for arg in names)
    values = ', '.join(names)
    return f'''#include <stdint.h>

// Generic arm64 register adapter for {name}: pointers/integers in x0...x3,
// pointer/integer result in x0 (ignored by callers of void functions).
// Request types and ownership: Sources/tgapi/RustBridge.{{h,m}}.
// The patch linker resolves Original to the checked host implementation.
__attribute__((visibility("hidden")))
extern uintptr_t Original({parameters});
extern void *objc_lookUpClass(const char *name);
extern void *sel_registerName(const char *name);
// Use a fixed signature so Apple's C ABI passes every argument in registers.
extern uintptr_t BridgeSend(void *bridge, void *method, {parameters}, void *original)
    __asm__("_objc_msgSend");

uintptr_t RustBridge_{name}({parameters}) {{
    void *bridge = objc_lookUpClass("TGExtraRustBridge");
    if (!bridge) {{
        return Original({values});
    }}
    void *method = sel_registerName({json.dumps(selector)});
    return BridgeSend(bridge, method, {values}, (void *)Original);
}}
'''


def payload_template(selector, arguments, original, source=None):
    return ipatch_payload(source if source is not None else payload_source(selector, arguments, original), 'bridge.'+original,
                          {'_Original': original, **{name: name for name in
                           ('_objc_lookUpClass', '_sel_registerName', '_objc_msgSend')}},
                          source_text=source is None)


def build_profile(macho, functions, imports, branches, usage, auth_info, constructor, marker_address, *, selectors):
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
        code, relocations = payload_template(selector, arguments, name)
        source = 'payloads/'+name+'.bin'
        files[source] = code
        files[source.removesuffix('.bin')+'.c'] = payload_source(selector, arguments, name).encode()
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
