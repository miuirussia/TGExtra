#!/usr/bin/env python3
"""Execute the shipped Pro payload and optionally plan it against a real IPA."""
import hashlib
import json
import os
from pathlib import Path
import platform
import struct
import subprocess
import sys
import tempfile
import unittest
import zipfile

ROOT = Path(__file__).resolve().parents[1]
PROFILE = ROOT/'Patches/swiftgram-pro-status-v1'
sys.path.insert(0, str(ROOT/'Tools'))
from package_ipatch import write_archive
from prepare_rust_patch import branch
from RustBridge.macho import MachO
from payloads import compile_payload


class SwiftgramProIpatchTests(unittest.TestCase):
    def test_c_adapter_matches_shipped_payload(self):
        code, fixups = compile_payload(PROFILE/'payloads/status.c')
        self.assertEqual(fixups, ())
        self.assertEqual(code, (PROFILE/'payloads/status.bin').read_bytes())

    @unittest.skipUnless(platform.system() == 'Darwin' and platform.machine() == 'arm64',
                         'requires native Apple Silicon execution')
    def test_payload_preserves_the_reviewed_witness_abi_and_error_path(self):
        with tempfile.TemporaryDirectory(prefix='tgextra-pro-ipatch-') as directory:
            root = Path(directory)
            # The witness matches the reviewed iOS function exactly except its
            # relocated BL. The stub returns an Int64 in x0 and a Swift error in x21.
            (root/'witness.s').write_text('''
.text
.p2align 2
.globl _RunStatus
_RunStatus:
stp x19, x20, [sp, #-32]!
stp x21, x30, [sp, #16]
mov x20, x3
mov x8, x2
mov x21, xzr
bl _Witness
str x21, [x20]
ldp x21, x30, [sp, #16]
ldp x19, x20, [sp], #32
ret
.globl _DecodeBody
_DecodeBody:
mov x21, x1
ret
.globl _Witness
_Witness:
str x19, [sp, #-32]!
stp x29, x30, [sp, #16]
add x29, sp, #16
mov x19, x8
bl _DecodeBody
cbnz x21, 1f
str x0, [x19]
1:
ldp x29, x30, [sp, #16]
ldr x19, [sp], #32
ret
''')
            (root/'main.c').write_text(r'''
#include <assert.h>
#include <stdint.h>
#include <stdio.h>
extern void RunStatus(int64_t, int64_t, int64_t *, int64_t *);
int main(int argc, char **argv) {
    const int64_t values[] = {INT64_MIN, -1, 0, 1, 2, 3, INT64_MAX};
    for (unsigned i = 0; i < sizeof(values)/sizeof(values[0]); i++) {
        for (int error = 0; error <= 7; error += 7) {
            int64_t result = 99, actualError = 0;
            RunStatus(values[i], error, &result, &actualError);
            int64_t expected = argc > 1 && values[i] < 2 ? 2 : values[i];
            assert(result == (error ? 99 : expected));
            assert(actualError == error);
        }
    }
    puts("PASS native Pro witness: signed Int64 bounds, higher statuses and Swift error path");
}
''')
            binary = root/'status-tests'
            subprocess.run(['clang', '-O2', '-Werror', str(root/'main.c'), str(root/'witness.s'),
                            str(PROFILE/'payloads/status.c'),
                            '-o', str(binary)], check=True)
            subprocess.run([str(binary)], check=True)
            symbols = {parts[-1]: int(parts[0], 16) for line in
                       subprocess.check_output(['nm', '-n', str(binary)], text=True).splitlines()
                       if len(parts := line.split()) == 3 and parts[1] in ('T', 't')}
            image = MachO(binary.read_bytes())
            witness, payload = symbols['_Witness'], symbols['_ProStatusPayload']
            profile = json.loads((PROFILE/'patch.json').read_text())['components'][0]['variants'][0]['binaries'][0]
            self.assertEqual(image.portable_fingerprint(witness, witness+40), profile['checks'][0]['assert']['function']['fingerprint'])
            code = (PROFILE/'payloads/status.bin').read_bytes()
            offset = image.offset(payload)
            self.assertEqual(image.data[offset:offset+len(code)], code, 'C adapter and shipped payload differ')
            patched = bytearray(image.data)
            struct.pack_into('<I', patched, image.offset(witness+24), branch(witness+24, payload))
            struct.pack_into('<I', patched, offset+16, branch(payload+16, witness+28))
            binary.write_bytes(patched)
            subprocess.run(['codesign', '-s', '-', '--force', str(binary)], check=True,
                           stdout=subprocess.DEVNULL)
            subprocess.run([str(binary), 'enabled'], check=True)

    @unittest.skipUnless(os.environ.get('IPATCH_ENGINE_CLI') and os.environ.get('SWIFTGRAM_REFERENCE_IPA'),
                         'requires a v4 engine and SWIFTGRAM_REFERENCE_IPA')
    def test_real_v4_feature_selection_and_profile(self):
        with tempfile.TemporaryDirectory(prefix='tgextra-pro-engine-') as directory:
            root = Path(directory)
            archive = root/'SwiftgramPro.ipatch'
            value = json.loads((PROFILE/'patch.json').read_text())
            write_archive(archive, value, {'payloads/status.bin': (PROFILE/'payloads/status.bin').read_bytes()})
            for enabled in (None, False, True):
                selection = root/'selection.json'
                selection.write_text(json.dumps({str(archive): ['swiftgram-pro'] if enabled else []}))
                command = [os.environ['IPATCH_ENGINE_CLI'], '-dry-run', '-ipa',
                           os.environ['SWIFTGRAM_REFERENCE_IPA'], '-package', str(archive)]
                if enabled is not None:
                    command.extend(['-feature-selection', str(selection)])
                process = subprocess.run(command, capture_output=True, text=True, timeout=180)
                self.assertEqual(process.returncode, 0, process.stdout + process.stderr)
                plan = json.loads(process.stdout)['plan']
                self.assertFalse(plan.get('tweaks'))
                self.assertFalse(plan.get('resources'))
                self.assertFalse(plan.get('generated_resources'))
                self.assertEqual(len(plan.get('patches') or []), int(bool(enabled)))
                if enabled:
                    patch = plan['patches'][0]
                    self.assertEqual(len(patch['edits']), 2)
                    with zipfile.ZipFile(os.environ['SWIFTGRAM_REFERENCE_IPA']) as ipa:
                        paths = [name for name in ipa.namelist() if name.endswith('/'+patch['path'])]
                        self.assertEqual(len(paths), 1)
                        original = ipa.read(paths[0])
                    self.assertEqual(hashlib.sha256(original).hexdigest(), patch['sha256'])
                    data = bytearray(original)
                    for edit in patch['edits']:
                        offset, expected = edit['offset'], bytes.fromhex(edit['expected'])
                        self.assertEqual(data[offset:offset+len(expected)], expected)
                        data[offset:offset+len(expected)] = bytes.fromhex(edit['replacement'])
                    linked = plan['profiles'][0]['plan']['anchors']
                    decode = linked['decode'][0]
                    slot = decode['file_offset']+24
                    self.assertEqual(data[slot:slot+4], struct.pack('<I', branch(decode['va']+24, linked['proStatus'][0]['va'])))
                    self.assertEqual(data[decode['file_offset']:slot], original[decode['file_offset']:slot])
                    self.assertEqual(data[slot+4:slot+16], original[slot+4:slot+16])


if __name__ == '__main__':
    unittest.main()
