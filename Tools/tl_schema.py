"""Read Telegram's embedded TLS1 v3 table; no local TL protocol definitions."""
import re
import struct
import zlib


def inflate_schema(data):
    matches = []
    for match in re.finditer(rb"\x78[\x01\x5e\x9c\xda]", data):
        offset = match.start()
        try:
            header = zlib.decompressobj().decompress(data[offset:offset + 4096], 72)
            if header[:8] != b"TLS1\x03\0\0\0":
                continue
            length = struct.unpack_from("<I", header, 16)[0]
            if not 72 <= length <= 16 * 1024 * 1024:
                continue
            stream = zlib.decompressobj()
            image = stream.decompress(data[offset:], length + 1)
            if not stream.eof or len(image) != length:
                continue
            consumed = len(data) - offset - len(stream.unused_data)
            schema = decode_schema(image)
            matches.append((data[offset:offset + consumed], schema))
        except (zlib.error, ValueError, struct.error, UnicodeDecodeError):
            continue
    if len(matches) != 1:
        raise ValueError(f"expected one embedded TLS1 v3 schema, found {len(matches)}")
    return matches[0]


def decode_schema(image):
    h = struct.unpack_from("<18I", image)
    if h[:2] != (0x31534C54, 3) or h[4] != len(image):
        raise ValueError("invalid TLS1 v3 header")
    for offset, count, stride in [(h[10], h[11], 1), (h[12], h[5], 12),
                                  (h[13], h[9], 4), (h[14], h[6], 28),
                                  (h[15], h[8], 20), (h[16], h[7], 28)]:
        if offset < 72 or offset + count * stride > len(image):
            raise ValueError("schema section is out of bounds")
    pool = image[h[10]:h[10] + h[11]]

    def string(offset):
        if not 0 <= offset < len(pool):
            raise ValueError("invalid schema string")
        return pool[offset:pool.index(b"\0", offset)].decode()

    types = [string(struct.unpack_from("<I", image, h[12] + 12 * i)[0]) for i in range(h[5])]
    fields = []
    for i in range(h[8]):
        values = struct.unpack_from("<IBBBBBbBBHHI", image, h[15] + 20 * i)
        name, kind, element, optional, boxed, bare, flags, bit, presence, typ, case, offset = values
        if kind > 7 or element > 7 or typ >= len(types) and typ != 65535:
            raise ValueError("invalid schema field")
        fields.append(dict(name=string(name).strip("`"), kind=kind, element=element,
                           optional=bool(optional), boxed=bool(boxed), bare=bool(bare),
                           flags_index=flags, flag_bit=bit, type_index=typ,
                           constructor_index=case))

    constructors = []
    for i in range(h[6]):
        name, signature, typ, case, first, count, _, _, _ = struct.unpack_from("<IIHHIHHIi", image, h[14] + 28 * i)
        if typ >= len(types) or first + count > len(fields):
            raise ValueError("invalid schema constructor")
        constructors.append(dict(name=string(name), id=signature, type=types[typ],
                                 type_index=typ, case_index=case, fields=fields[first:first + count]))
    if any(a["id"] >= b["id"] for a, b in zip(constructors, constructors[1:])):
        raise ValueError("constructors are not ordered")
    functions = []
    for i in range(h[7]):
        name, signature, first, count, _, result, _, _ = struct.unpack_from("<IIIHHIIi", image, h[16] + 28 * i)
        if first + count > len(fields) or result >= len(fields):
            raise ValueError("invalid schema function")
        functions.append(dict(name=string(name), id=signature, fields=fields[first:first + count], result=fields[result]))
    return dict(types=types, constructors=constructors, functions=functions)
