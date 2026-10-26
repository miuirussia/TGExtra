#!/usr/bin/env python3
import hashlib
from pathlib import Path
import struct
import sys
import unittest
sys.path.insert(0, str(Path(__file__).resolve().parents[1]/'Tools'))
from prepare_rust_patch import identify, branch
from RustBridge.macho import normalized


class RelinkedCode:
    def __init__(self, prefix=0, relocation=0, duplicate=False):
        self.data = bytearray(prefix)
        self.starts, self.ends, self.profile = [], [], {'functions': {}}
        functions = ['bufferData', 'bufferFree', 'bufferLength', 'abi', 'engineCreate', 'sessionCreate', 'sessionDestroy', 'send', 'cancel']
        for index, name in enumerate(functions):
            self.starts.append(len(self.data))
            # Different constants carry meaning; link-time branch displacements
            # can vary without changing the reviewed implementation.
            code = struct.pack('<III', 0xD2800000 | index << 5, 0x94000000 | relocation, 0xD65F03C0)
            if name == 'bufferData': code = bytes.fromhex('400000b4000440f9c0035fd6')
            if name == 'bufferLength': code = bytes.fromhex('400000b4000840f9c0035fd6')
            self.data += code
            self.ends.append(len(self.data))
            original = struct.pack('<III', 0xD2800000 | index << 5, 0x94000000, 0xD65F03C0)
            spec = {'size': 12, 'sha256': hashlib.sha256(normalized(original)).hexdigest()}
            if name in ('bufferData', 'bufferLength'):
                spec.update(sha256=hashlib.sha256(normalized(code)).hexdigest(), exact=code.hex())
            self.profile['functions'][name] = spec
        if duplicate:
            self.starts.append(len(self.data)); self.data += self.data[self.starts[7]:self.ends[7]]; self.ends.append(len(self.data))

    def offset(self, address): return address
    def fingerprint(self, start, end): return hashlib.sha256(normalized(self.data[start:end])).hexdigest()


class RustPatchTests(unittest.TestCase):
    def test_relinked_clients_derive_new_addresses(self):
        telegram, swiftgram = RelinkedCode(4096), RelinkedCode(16384, 1234)
        original = identify(telegram, telegram.profile)
        fork = identify(swiftgram, telegram.profile)
        for name in original:
            self.assertEqual(fork[name]-original[name], 12288)

    def test_unknown_or_ambiguous_implementation_is_rejected(self):
        changed = RelinkedCode(4096)
        changed.data[changed.starts[7]] ^= 0x20
        with self.assertRaises(ValueError): identify(changed, changed.profile)
        ambiguous = RelinkedCode(4096, duplicate=True)
        with self.assertRaises(ValueError): identify(ambiguous, ambiguous.profile)

    def test_reviewed_variant_keeps_original_and_rejects_unknown_or_ambiguous_code(self):
        original, variant = RelinkedCode(4096), RelinkedCode(4096)
        start, end = variant.starts[4], variant.ends[4]
        variant.data[start+1] ^= 0x08
        spec = original.profile['functions']['engineCreate']
        spec['variants'] = [{'reference': 'Reviewed fork', 'sha256': variant.fingerprint(start, end)}]
        self.assertEqual(identify(original, original.profile)['engineCreate'], start)
        self.assertEqual(identify(variant, original.profile)['engineCreate'], start)
        variant.data[start+1] ^= 0x10
        with self.assertRaises(ValueError): identify(variant, original.profile)
        variant.data[start+1] ^= 0x10
        original.starts.append(len(original.data))
        original.data += variant.data[start:end]
        original.ends.append(len(original.data))
        with self.assertRaises(ValueError): identify(original, original.profile)

    def test_fingerprints_preserve_semantic_offsets(self):
        getter = bytes.fromhex('000440f9')
        different_field = bytes.fromhex('000840f9')
        self.assertNotEqual(normalized(getter), normalized(different_field))
        self.assertEqual(normalized(bytes.fromhex('08000090000540f9')), normalized(bytes.fromhex('08000090000940f9')))
        self.assertNotEqual(normalized(bytes.fromhex('00200091')), normalized(bytes.fromhex('00400091')))

    def test_branch_limits_and_alignment(self):
        self.assertEqual(branch(0x100, 0x104), 0x14000001)
        self.assertEqual(branch(0x104, 0x100, True), 0x97FFFFFF)
        for target in (3, 1 << 27, -(1 << 27)-4):
            with self.assertRaises(ValueError): branch(0, target)


if __name__ == '__main__': unittest.main()
