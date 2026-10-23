#!/usr/bin/env python3
"""Execute the production arm64 thunk generator against real macOS ObjC ABI."""
import platform
from pathlib import Path
import subprocess
import sys
import tempfile
sys.path.insert(0, str(Path(__file__).resolve().parents[1]/'Tools'))
from prepare_rust_patch import thunk, MachO


def main():
    if platform.system() != 'Darwin' or platform.machine() != 'arm64':
        print('SKIP native arm64 thunk execution (requires Apple Silicon macOS)')
        return
    with tempfile.TemporaryDirectory(prefix='tgextra-thunks-') as directory:
        root = Path(directory)
        asm = root/'thunks.s'
        asm.write_text('\n'.join(f'.text\n.p2align 12\n.globl _RustThunk{name}\n_RustThunk{name}:\n.space 4096' for name in (1, 2, 3, 4, 'Fallback'))+'\n')
        executable = root/'thunks'
        subprocess.run(['clang', '-fobjc-arc', '-Werror', str(Path(__file__).with_suffix('.m')), str(asm), '-framework', 'Foundation', '-o', str(executable)], check=True)
        symbols = {}
        for line in subprocess.check_output(['nm', '-n', str(executable)], text=True).splitlines():
            parts = line.split()
            if len(parts) == 3:
                symbols[parts[2]] = int(parts[0], 16)
        data = bytearray(executable.read_bytes())
        macho = MachO(data)
        assert symbols["_RustOriginal1"] in macho.starts, "function starts must use the nonzero __TEXT VM base"
        imports = macho.imports()
        selectors = ['one:original:', 'two:b:original:', 'three:b:c:original:', 'four:b:c:d:original:']
        for number, selector in enumerate(selectors, 1):
            address = symbols[f'_RustThunk{number}']
            code = thunk(address, symbols[f'_RustOriginal{number}'], selector, number, imports)
            off = macho.offset(address)
            data[off:off+len(code)] = code
        address = symbols['_RustThunkFallback']
        code = thunk(address, symbols['_RustOriginal4'], selectors[-1], 4, imports)
        code = code.replace(b'TGExtraRustBridge\0', b'AbsentRustBridge!\0')
        off = macho.offset(address)
        data[off:off+len(code)] = code
        executable.write_bytes(data)
        subprocess.run(['codesign', '-s', '-', '--force', str(executable)], check=True, stdout=subprocess.DEVNULL)
        subprocess.run([str(executable)], check=True)


if __name__ == '__main__':
    main()
