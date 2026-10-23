"""Small read-only arm64 Mach-O reader and linker-independent fingerprints."""
import bisect
import hashlib
import struct


def signed(value, bits):
    return (value ^ (1 << (bits - 1))) - (1 << (bits - 1))


def normalized(code):
    words, pages = [], set()
    for (word,) in struct.iter_unpack('<I', code):
        rd, rn = word & 31, word >> 5 & 31
        if word & 0x7C000000 == 0x14000000:  # B / BL
            word &= 0xFC000000
            pages.clear()
        elif word & 0x9F000000 == 0x90000000:  # ADRP: link-time page
            word &= 0x9F00001F
            pages.add(rd)
            words.append(word)
            continue
        elif word & 0x9F000000 == 0x10000000:  # ADR
            word &= 0x9F00001F
        elif word & 0xFF000010 == 0x54000000 or word & 0x7E000000 == 0x34000000:
            word &= ~0xFFFFE0
            pages.clear()
        elif word & 0x7E000000 == 0x36000000:
            word &= ~0x7FFE0
            pages.clear()
        elif word & 0x3B000000 == 0x18000000:  # literal load
            word &= ~0xFFFFE0
        elif word & 0x7FC00000 == 0x11000000 and rn in pages:
            word &= ~0x3FFC00  # ADD of a link-time low page offset
        elif word & 0x3B000000 == 0x39000000:
            if rn in pages:
                word &= ~0x3FFC00  # load/store of a link-time page offset
            # Stores and SIMD loads do not overwrite an integer register.
            if not word & 0x00400000 or word & 0x04000000:
                words.append(word)
                continue
        # Never mask ordinary field offsets, arithmetic constants or struct
        # layout. Unknown writes conservatively invalidate page provenance.
        pages.discard(rd)
        words.append(word)
    return struct.pack('<' + 'I' * len(words), *words)


class MachO:
    def __init__(self, data):
        self.data = data
        if len(data) < 32 or data[:4] != b'\xcf\xfa\xed\xfe':
            raise ValueError('expected a thin little-endian 64-bit Mach-O')
        if self.u32(4) != 0x0100000C or self.u32(8) & 0xFFFFFF != 0:
            raise ValueError('only generic arm64 is supported for offline Rust thunks')
        self.sections = {}
        self.segments = []
        self.starts = []
        self.encrypted = False
        self.uuid = None
        count, size = struct.unpack_from('<II', data, 16)
        self.command_end = 32 + size
        pos = 32
        for _ in range(count):
            cmd, length = struct.unpack_from('<II', data, pos)
            if length < 8 or pos + length > self.command_end:
                raise ValueError('invalid load command')
            if cmd == 0x19:
                name = data[pos+8:pos+24].rstrip(b'\0').decode()
                vm, vmsize, off, filesize = struct.unpack_from('<QQQQ', data, pos+24)
                self.segments.append((name, vm, off, filesize))
                for i in range(self.u32(pos+64)):
                    p = pos+72+80*i
                    section = data[p:p+16].rstrip(b'\0').decode()
                    addr, size = struct.unpack_from('<QQ', data, p+32)
                    self.sections[section] = (addr, self.u32(p+48), size)
            elif cmd == 0x1B:
                self.uuid = data[pos+8:pos+24]
            elif cmd in (0x21, 0x2C):
                self.encrypted |= self.u32(pos+16) != 0
            elif cmd == 0x26:
                start, size = struct.unpack_from('<II', data, pos+8)
                p, end, addr = start, start+size, 0
                while p < end:
                    value, shift = 0, 0
                    while True:
                        b = data[p]; p += 1
                        value |= (b & 127) << shift; shift += 7
                        if not b & 128:
                            break
                        if shift > 63:
                            raise ValueError('invalid function starts')
                    if not value:
                        break
                    addr += value
                    self.starts.append(addr)
            pos += length
        if pos != self.command_end or not self.uuid or not self.starts:
            raise ValueError('missing/invalid UUID or function starts')
        if self.encrypted:
            raise ValueError('Rust image is encrypted; supply a decrypted IPA')
        text_base = next(vm for name, vm, _, _ in self.segments if name == '__TEXT')
        self.starts = [text_base+offset for offset in self.starts]
        self.text, self.textoff, self.textsize = self.sections['__text']
        self.ends = self.starts[1:] + [self.text+self.textsize]

    def u32(self, pos):
        return struct.unpack_from('<I', self.data, pos)[0]

    def offset(self, address):
        for _, vm, off, size in self.segments:
            if vm <= address < vm+size:
                return off+address-vm
        raise ValueError(f'address {address:#x} is outside file-backed segments')

    def function(self, address):
        i = bisect.bisect_right(self.starts, address)-1
        return self.starts[i], self.ends[i]

    def branches(self):
        for off in range(self.textoff, self.textoff+self.textsize, 4):
            word = self.u32(off)
            if word & 0x7C000000 == 0x14000000:
                pc = self.text+off-self.textoff
                yield pc, pc + signed(word & 0x3FFFFFF, 26)*4

    def fingerprint(self, start, end):
        off = self.offset(start)
        return hashlib.sha256(normalized(self.data[off:off+end-start])).hexdigest()

    def references(self, target):
        for off in range(self.textoff, self.textoff+self.textsize-24, 4):
            word = self.u32(off)
            if word & 0x9F000000 != 0x90000000:
                continue
            pc = self.text+off-self.textoff
            page = (pc & ~4095) + signed(((word >> 5 & 0x7FFFF) << 2) | (word >> 29 & 3), 21)*4096
            if page != target & ~4095:
                continue
            for step in range(1, 7):
                add = self.u32(off+4*step)
                if add & 0xFFC00000 == 0x91000000 and add >> 5 & 31 == word & 31 and add >> 10 & 4095 == target & 4095:
                    yield pc

    def objc_stub(self, address, selector):
        section = self.sections.get('__objc_stubs')
        if not section or not section[0] <= address < section[0]+section[2]:
            return False
        off = self.offset(address)
        adrp, load = struct.unpack_from('<II', self.data, off)
        if adrp & 0x9F00001F != 0x90000001 or load & 0xFFC003FF != 0xF9400021:
            return False
        page = (address & ~4095) + signed(((adrp >> 5 & 0x7FFFF) << 2) | (adrp >> 29 & 3), 21)*4096
        pointer = self.offset(page + (load >> 10 & 4095)*8)
        # DYLD_CHAINED_PTR_64(_OFFSET): low 36 bits are the rebase target.
        target = struct.unpack_from('<Q', self.data, pointer)[0] & ((1 << 36)-1)
        try:
            off = self.offset(target)
        except ValueError:
            return False
        return self.data[off:off+len(selector)+1] == selector.encode()+b'\0'

    def imports(self):
        pos, symtab, indirect = 32, None, None
        for _ in range(self.u32(16)):
            cmd, size = struct.unpack_from('<II', self.data, pos)
            if cmd == 2:
                symtab = struct.unpack_from('<IIII', self.data, pos+8)
            elif cmd == 0xB:
                indirect = struct.unpack_from('<II', self.data, pos+56)
            elif cmd == 0x19:
                for i in range(self.u32(pos+64)):
                    p = pos+72+80*i
                    if self.data[p:p+16].rstrip(b'\0') == b'__stubs':
                        index, stride = struct.unpack_from('<II', self.data, p+68)
            pos += size
        if not symtab or not indirect:
            raise ValueError('missing import symbol tables')
        off, count, strings, _ = symtab
        addr, _, size = self.sections['__stubs']
        result = {}
        for i in range(size//stride):
            symbol = self.u32(indirect[0]+(index+i)*4)
            if symbol >= count:
                continue
            string = strings+self.u32(off+symbol*16)
            name = self.data[string:self.data.index(b'\0', string)].decode()
            result[name] = addr+i*stride
        return result
