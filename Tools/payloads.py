"""Compile small arm64 C bridges and translate Mach-O fixups into iPatch relocations.

Only code, C strings, direct branches and adjacent ADRP/ADD pairs are accepted.
Unexpected compiler output is rejected rather than copied into a client image.
"""
from functools import lru_cache
from pathlib import Path
import struct
import subprocess
import tempfile


@lru_cache(maxsize=None)
def compile_payload(source):
    with tempfile.TemporaryDirectory(prefix='tgextra-payload-') as directory:
        obj = Path(directory)/'payload.o'
        subprocess.run(['clang', '-target', 'arm64-apple-macos14', '-O2', '-Werror',
                        '-fno-stack-protector', '-fno-unwind-tables',
                        '-c', str(source), '-o', str(obj)], check=True)
        return object_payload(obj.read_bytes())


@lru_cache(maxsize=None)
def compile_source(source):
    with tempfile.TemporaryDirectory(prefix='tgextra-payload-source-') as directory:
        path = Path(directory)/'payload.c'
        path.write_text(source)
        return compile_payload(path)


def object_payload(data):
    if struct.unpack_from('<III', data) != (0xfeedfacf, 0x100000c, 0):
        raise ValueError('payload must be a generic arm64 Mach-O object')
    if struct.unpack_from('<I', data, 12)[0] != 1:
        raise ValueError('payload must be an unlinked object')
    sections, symbols = [], []
    position = 32
    for _ in range(struct.unpack_from('<I', data, 16)[0]):
        command, length = struct.unpack_from('<II', data, position)
        if command == 0x19:  # LC_SEGMENT_64
            for i in range(struct.unpack_from('<I', data, position+64)[0]):
                at = position+72+i*80
                name = data[at:at+16].rstrip(b'\0').decode()
                address, size, offset, align, reloc, count = struct.unpack_from('<QQIIII', data, at+32)
                sections.append(dict(name=name, address=address, size=size, offset=offset,
                                     align=align, reloc=reloc, count=count))
        elif command == 2:  # LC_SYMTAB
            symoff, nsyms, stroff, _ = struct.unpack_from('<IIII', data, position+8)
            for i in range(nsyms):
                string, kind, section, _, value = struct.unpack_from('<IBBHQ', data, symoff+i*16)
                end = data.index(b'\0', stroff+string)
                symbols.append((data[stroff+string:end].decode(), kind, section, value))
        position += length
    code = bytearray()
    for section in sections:
        if section['size'] and section['name'] not in ('__text', '__cstring'):
            raise ValueError(f"unsupported payload section: {section['name']}")
        if section['align'] > 4:
            raise ValueError('unexpected payload alignment')
        code.extend(b'\0' * (-len(code) % (1 << section['align'])))
        section['output'] = len(code)
        code.extend(data[section['offset']:section['offset']+section['size']])
    if not sections or sections[0]['name'] != '__text' or not sections[0]['size']:
        raise ValueError('payload must start with its code section')
    entries = [value for _, kind, section, value in symbols if kind == 0xf and section == 1]
    if entries != [sections[0]['address']]:
        raise ValueError('payload must have exactly one public entry at offset zero')
    fixups = []
    for section in sections:
        pages, adds = {}, {}
        for i in range(section['count']):
            offset, flags = struct.unpack_from('<II', data, section['reloc']+i*8)
            symbol, pcrel, size, external, kind = flags & 0xffffff, flags >> 24 & 1, flags >> 25 & 3, flags >> 27 & 1, flags >> 28
            if not external or size != 2 or kind not in (2, 3, 4):
                raise ValueError('unsupported payload relocation')
            name, symkind, index, value = symbols[symbol]
            if symkind & 0xe == 0xe:  # N_SECT: local C string
                target_section = sections[index-1]
                if target_section['name'] != '__cstring':
                    raise ValueError('unexpected local payload reference')
                target = target_section['output']+value-target_section['address']
            elif symkind & 0xe == 0:  # N_UNDF: host function
                target = name
            else:
                raise ValueError('unsupported payload symbol')
            at = section['output']+offset
            word = struct.unpack_from('<I', code, at)[0]
            if kind == 2 and pcrel and word & 0x7fffffff == 0x14000000:
                fixups.append(('bl' if word >> 31 else 'b', at, target))
            elif kind == 3 and pcrel and word & 0xffffffe0 == 0x90000000:
                pages[offset] = (target, word & 31)
            elif kind == 4 and not pcrel and word & 0xffc00000 == 0x91000000:
                # PAGEOFF12 precedes PAGE21 in Apple's relocation tables.
                adds[offset] = (target, word)
            else:
                raise ValueError('unexpected instruction at payload relocation')
        for offset, (target, register) in pages.items():
            low_target, add = adds.get(offset+4, (None, 0))
            if low_target != target or add & 0x3ffc00 or add & 31 != register or add >> 5 & 31 != register:
                raise ValueError('payload address must use an adjacent ADRP/ADD pair')
            fixups.append(('adrp_add', section['output']+offset, target))
        if set(adds) != {offset+4 for offset in pages}:
            raise ValueError('unpaired payload address relocation')
    code.extend(b'\0' * (-len(code) % 4))
    return bytes(code), tuple(sorted(fixups, key=lambda item: item[1]))


def ipatch_payload(source, block, anchors, *, source_text=False):
    code, fixups = compile_source(source) if source_text else compile_payload(source)
    relocations = []
    for kind, offset, target in fixups:
        relocation = {'type': kind, 'offset': offset}
        if isinstance(target, int):
            relocation.update(anchor=block, addend=target)
        else:
            if target not in anchors: raise ValueError(f'unexpected payload import: {target}')
            relocation['anchor'] = anchors[target]
        relocations.append(relocation)
    return code, relocations


def link_payload(code, relocations, start, addresses):
    code = bytearray(code)
    for relocation in relocations:
        offset = relocation['offset']
        pc = start+offset
        target = addresses[relocation['anchor']]+relocation.get('addend', 0)
        kind = relocation['type']
        word = struct.unpack_from('<I', code, offset)[0]
        if kind in ('b', 'bl'):
            delta = target-pc
            if delta % 4 or not -(1 << 27) <= delta < 1 << 27:
                raise ValueError('arm64 branch is out of range')
            struct.pack_into('<I', code, offset, word & 0xfc000000 | (delta//4 & 0x3ffffff))
        elif kind == 'adrp_add':
            pages = ((target & ~4095)-(pc & ~4095))//4096
            if not -(1 << 20) <= pages < 1 << 20:
                raise ValueError('arm64 ADRP out of range')
            add = struct.unpack_from('<I', code, offset+4)[0]
            pages &= 0x1fffff
            struct.pack_into('<II', code, offset,
                             word & 0x9f00001f | (pages & 3) << 29 | (pages >> 2) << 5,
                             add & ~0x3ffc00 | (target & 4095) << 10)
        else:
            raise ValueError(f'unsupported payload relocation: {kind}')
    return bytes(code)
