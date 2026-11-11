# Updating TGExtra patches for Telegram and Swiftgram

[Русская версия](UPDATING.ru.md)

This guide is for someone who can run terminal commands but has never worked
with assembly language. It covers updating TGExtra compatibility profiles for
new **iOS IPAs** of Telegram and Swiftgram.

Start with the automatic updater. You only need to read machine code if the new
build fails the existing checks. In that case, determine what changed in the
program and verify that the patch still behaves correctly. Changing a version
number or hash alone does not establish compatibility.

The current reference builds documented in this repository are **Telegram
13.2.1 (36542)** and **Swiftgram 13.1.3 (360, `app.swiftgram.ios`)**. These are
reviewed starting points; they do not establish support for every newer version.

## Contents

1. [What gets updated](#what-gets-updated)
2. [Preparing your workspace](#preparing-your-workspace)
3. [Updating without assembly knowledge](#updating-without-assembly-knowledge)
4. [Validation and IPA building](#validation-and-ipa-building)
5. [Common errors](#common-errors)
6. [ARM64 basics for reading patches](#arm64-basics-for-reading-patches)
7. [Finding code in a new version](#finding-code-in-a-new-version)
8. [Updating each patch family](#updating-each-patch-family)
9. [Testing on a device](#testing-on-a-device)
10. [What to commit](#what-to-commit)
11. [Quick reference](#quick-reference)

## What gets updated

An IPA is an application archive. It contains the executable, libraries,
resources, and an `Info.plist` with application metadata. iOS executables use the
**Mach-O** format. Their compiled code can be displayed as assembly instructions;
this process is called **disassembly**.

Several separate parts are involved in TGExtra:

| Part | Contents and purpose |
| --- | --- |
| TGExtra DEB | The tweak itself: settings, message processing, and feature implementations |
| `Patches/<id>/patch.json` | A profile describing how to find, validate, and modify the relevant code |
| `payloads/*.c` | Source code for small adapters between the application and the tweak |
| `payloads/*.bin` | Compiled adapters inserted into the application |
| `.ipatch` | An engine package containing profiles, adapters, and, in the complete TGExtra package, the matching DEB |
| `Tools/update_patches.py` | The combined script that attempts to update the profiles |

A **compatibility profile** describes a reviewed piece of code. A function's
address may change between builds, so the engine identifies it through features
such as instruction fingerprints, Swift type structure, relationships between
functions, and call counts.

A **payload**, or adapter, is a small piece of code through which a selected
call is redirected. It usually calls TGExtra and falls through to the original
function if the tweak is absent. Swiftgram Pro uses a separate insertion that
changes the stored value and does not require TGExtra at runtime.

The repository contains four families:

| Family | Directory | What an update requires |
| --- | --- | --- |
| Native TL Decoder | `Patches/native-tl-v1` | Review the TL parsers and their call sites; also update the runtime matcher |
| Rust MTProto Bridge | `Patches/rust-abi5-*` | Review Rust functions, the ABI, session bindings, and calls; generate a profile for each compatible client |
| Secret Chat Protection | `Patches/secret-chats-v1` | Review five interception sites and their original targets; the generator requires both IPAs |
| Swiftgram Pro | `Patches/swiftgram-pro-status-v1` | Review Swift metadata and the decoder; there is no automatic generator for changed code |

The first three belong to the mandatory **TGExtra** component, with the ID
`required`. **Swiftgram Pro** is a separate optional component,
`swiftgram-pro`, disabled by default.

Updating these profiles does not automatically adapt to changes in Telegram's
interface, UI hooks, or API schema. For example, a missing settings button may
require changes to the tweak's source even when the binary patches are fully
compatible.

## Preparing your workspace

### System and tools

Use macOS with Xcode tools for this workflow. An Intel Mac can generate patches
and run some checks. Tests that execute ARM64 machine code require an Apple
Silicon Mac. The full test suite also uses the Mac Catalyst SDK and the Logos
preprocessor; see the [main README](../README.md#building) for build environment
setup.

Check the tools:

```sh
python3 --version
git --version
xcode-select -p
xcrun --find clang
xcrun --find swiftc
```

If the Xcode command line tools are missing:

```sh
xcode-select --install
```

Generating adapters requires Apple Clang: the scripts invoke it through `xcrun`.
Having a regular `clang` installation on Linux does not provide this environment.

You also need an **ipatch CLI supporting format v4**. Download links are in the
[installation section](../README.md#patching-an-ipa-with-ipatch). For Secret
Chats, the engine must support the `dylib` field on `import_stub` anchors.

Save the CLI as, for example, `~/Tools/ipatch`, then run:

```sh
chmod +x "$HOME/Tools/ipatch"
export IPATCH_ENGINE_CLI="$HOME/Tools/ipatch"
```

The variable applies to the current terminal session. Set it again in a new
window. Replace the example path with your actual path if necessary.

### Original applications

Use original, **decrypted** IPAs without previously injected tweaks or patches.
Renaming a ZIP or removing a signature is insufficient: the application's code
must be readable. The generator stops if the Mach-O is encrypted.

These generators expect a **thin generic arm64** image: one architecture variant
in the file. An `arm64e` image or a FAT file containing multiple architectures is
not a suitable reference input for these generators. The engine itself can
apply Rust profiles to the arm64 slice of a supported FAT file; the generator
and engine have different capabilities here.

Place the new IPAs in `packages/`. The following commands use placeholder names:

```text
packages/Telegram_new.ipa
packages/Swiftgram_new.ipa
```

Replace them with your actual filenames in every command. Keep the old reference
IPAs separately for comparison and checks of existing compatibility.

Record each file's version, build number, and bundle ID. You can read these
without extracting the entire archive:

```sh
python3 - packages/Telegram_new.ipa packages/Swiftgram_new.ipa <<'PY'
import plistlib
import sys
import zipfile

for filename in sys.argv[1:]:
    with zipfile.ZipFile(filename) as archive:
        entries = [name for name in archive.namelist()
                   if name.startswith('Payload/') and name.count('/') == 2
                   and name.endswith('/Info.plist')]
        if len(entries) != 1:
            raise SystemExit(f'{filename}: expected one top-level Info.plist')
        info = plistlib.loads(archive.read(entries[0]))
    print(filename)
    for key in ('CFBundleShortVersionString', 'CFBundleVersion', 'CFBundleIdentifier'):
        print(f'  {key}: {info.get(key)}')
PY
```

Record the SHA-256 hashes to identify the exact input archives:

```sh
shasum -a 256 packages/Telegram_new.ipa packages/Swiftgram_new.ipa
```

This hash identifies an archive. It does not replace the function fingerprints
used in profiles.

### A separate branch

Open a terminal at the TGExtra repository root. It should contain `Tools`,
`Patches`, `Sources`, and `Tests`.

```sh
git status --short
git switch -c patches/update-clients
```

If you already have unfinished changes, save your work using your usual workflow
first, so you can distinguish it from the generated changes. Git ignores the
`packages/` directory: input IPAs do not need to be committed.

## Updating without assembly knowledge

### Check without writing first

```sh
python3 Tools/update_patches.py \
  --telegram packages/Telegram_new.ipa \
  --swiftgram packages/Swiftgram_new.ipa \
  --engine "$IPATCH_ENGINE_CLI" \
  --check
```

The script works in temporary copies. With `--check`, it compares the generated
source files with the repository without changing your working files. Missing
ignored `.bin` files do not count as source changes in this mode.

Possible messages:

| Message | Meaning and next step |
| --- | --- |
| `up to date` | The generated source files already match the repository |
| `generated files differ` | Generation succeeded but produced changes; rerun without `--check` to save them |
| `unrecognized`, `ambiguous`, `ABI changed` | The code or its recognition needs investigation; see the corresponding error below |
| `No Rust runtime` | No Rust runtime was found; no new Rust profile is generated, and the existing MtProtoKit hooks apply |
| `skipped` | This stage was not checked; read the stated reason |

Exit codes:

- `0`: all attempted stages succeeded;
- `1`: at least one attempt failed, including differences found with `--check`;
- `2`: invalid arguments or ambiguous IPA selection.

Exit code `0` does not mean that skipped stages ran or that device testing passed.

### Save the result

To write the generated profiles, repeat the command without `--check`:

```sh
python3 Tools/update_patches.py \
  --telegram packages/Telegram_new.ipa \
  --swiftgram packages/Swiftgram_new.ipa \
  --engine "$IPATCH_ENGINE_CLI"
```

The script attempts the following stages in sequence:

1. Generate the shared Native TL profile and check it against both clients.
2. Generate a Rust profile separately for each IPA that contains Rust.
3. Generate Secret Chats using both IPAs.
4. Validate the existing Swiftgram Pro profile with its optional component enabled.

With `--engine`, every resulting profile must pass the engine's planner before
being copied into the working directory. Planning computes changes without
applying them to the original IPA.

**Isolation applies to each individual attempt.** If Native TL fails, Rust can
still update successfully and be saved. A failed attempt leaves its profile
unchanged. The entire run is not one transaction that rolls back all successful
stages. The script does not modify the input IPAs.

### Review the changes

```sh
git status --short
git diff --stat
git diff -- Patches Sources/tgapiC/NativeTLProfile.inc
```

Check what the changes mean:

- A new `rust-abi5-...` directory may be an expected new profile. Existing Rust
  profiles are retained during updates.
- `Sources/tgapiC/NativeTLProfile.inc` should change alongside the corresponding
  Native TL update: it is part of parser recognition inside the tweak.
- Changed adapter sizes and relocations must match the compiler output.
  Different Apple Clang versions can produce different adapter binaries and
  Rust profile IDs.
- Weakened checks, missing original-target checks, or accidentally added bundle
  IDs are not routine parts of an update.

Then rerun the command with `--check`. If it reports compatible but different
output immediately after generation, investigate the reproducibility problem
before proceeding.

### When you only have one IPA

Pass one client explicitly and use an empty discovery directory to prevent the
script from picking up a second client from `packages/`:

```sh
mkdir -p packages/empty-discovery
python3 Tools/update_patches.py \
  --packages packages/empty-discovery \
  --telegram packages/Telegram_new.ipa \
  --engine "$IPATCH_ENGINE_CLI"
```

For Swiftgram, replace `--telegram` with `--swiftgram`. Secret Chats is skipped
in this case because its generator requires both IPAs. When updating the shared
Native TL profile, separately verify compatibility with the other client.

Generation can also run without `--engine` and without the `IPATCH_ENGINE_CLI`
variable, but engine validation and Swiftgram Pro checks are skipped. Perform
those checks separately before a release. A successful Python run alone does
not establish that they passed.

## Validation and IPA building

### Rebuild the adapters

```sh
python3 Tools/build_payloads.py
python3 Tools/build_payloads.py --check
```

The first command creates `.bin` files from the C sources and updates the related
sizes, relocations, and Rust profile IDs when necessary. The second checks that
they agree. Rebuilding compiles the adapters already described in the repository;
it does not make unknown Telegram code compatible.

Run the first command before checking a fresh checkout because `.bin` files are
not stored in Git. The full `bash Tests/run.sh` command rebuilds them automatically.

### Run the tests

On a prepared macOS system:

```sh
export IPATCH_ENGINE_CLI="$HOME/Tools/ipatch"
export SWIFTGRAM_REFERENCE_IPA="$PWD/packages/Swiftgram_new.ipa"
bash Tests/run.sh
```

To run the patch checks individually after rebuilding the adapters:

```sh
python3 Tests/update_patches.py
python3 Tests/native_tl_profile.py
python3 Tests/rust_portable.py
python3 Tests/secret_chats.py
python3 Tests/swiftgram_pro_ipatch.py
python3 Tests/ipatch_packaging.py
```

The tests use the environment variables set above. `SWIFTGRAM_REFERENCE_IPA`
selects the IPA for Pro validation, but **does not switch every other test**.
Some Native TL, Rust, and Secret Chats checks look for fixed reference filenames:
`packages/Telegram_v13.2.1.ipa` and `packages/Swiftgram_v13.1.3_360.ipa`.
Some checks simply omit the comparison if those files are missing.

Keep the actual old references under their original names. Always validate the
new IPA through `update_patches.py --engine` and the complete package described
below. When adding a permanent new reference, extend the relevant tests using
its real filename. Renaming a new version to an old reference name hides which
build was actually checked.

Read `skipped` messages: a missing CLI, IPA, or Apple Silicon machine means the
corresponding check did not run. Passing tests with skips does not establish
that all adapters executed or that both new clients were validated.

### Build the complete package

Use a DEB built from the same source revision as the profiles. This matters
especially after changing the runtime matcher or adapter contracts.

```sh
python3 Tools/package_ipatch.py \
  --deb packages/TGExtra.deb \
  --patches Patches \
  --output packages/TGExtra-updated.ipatch
```

`packages/TGExtra.deb` is a placeholder: substitute the actual DEB for the
installation variant you need. The package includes profiles from `Patches`
and their adapters. For the full local DEB and ipatch build cycle covering all
three installation variants, use `./build-arm64.sh` as described in the main
README.

### Validate the complete plan for the new clients

```sh
"$IPATCH_ENGINE_CLI" -dry-run -explain \
  -ipa packages/Telegram_new.ipa \
  -package packages/TGExtra-updated.ipatch

"$IPATCH_ENGINE_CLI" -dry-run -explain \
  -ipa packages/Swiftgram_new.ipa \
  -package packages/TGExtra-updated.ipatch
```

Separately validate Swiftgram with Pro enabled:

```sh
"$IPATCH_ENGINE_CLI" -dry-run -explain \
  -ipa packages/Swiftgram_new.ipa \
  -package packages/TGExtra-updated.ipatch \
  -feature packages/TGExtra-updated.ipatch:swiftgram-pro
```

The prefix in `-feature` must match the path passed to `-package`. A successful
run with Pro disabled by default does not validate Pro compatibility.

The plan should resolve the expected profiles for that client, edit locations,
adapters, and generated metadata. For the corresponding profiles, examples
include `TGExtraNativeTL.plist`, `TGExtraRustBridge.plist`, and
`TGExtraSecretChats.plist`. Missing Rust metadata is expected only for a client
without Rust. Investigate an unexpectedly empty plan or a missing patch family.

### Apply to copies and install

After validation succeeds:

```sh
"$IPATCH_ENGINE_CLI" -apply \
  -ipa packages/Telegram_new.ipa \
  -package packages/TGExtra-updated.ipatch \
  -output packages/Telegram-TGExtra.ipa

"$IPATCH_ENGINE_CLI" -apply \
  -ipa packages/Swiftgram_new.ipa \
  -package packages/TGExtra-updated.ipatch \
  -output packages/Swiftgram-TGExtra.ipa
```

To enable Pro, add the same `-feature` argument shown above to the Swiftgram
command. Add `-sideload` if sideload compatibility is needed. The output uses
ad hoc signing; sign and install it with your IPA installation tool. See the
main README for installation details.

Start each new experiment from an original IPA. To disable Pro, also rebuild
from the original with the Pro component turned off.

## Common errors

| Message or symptom | What to check |
| --- | --- |
| `no reference IPAs` | IPA paths, file existence, and the `--telegram` / `--swiftgram` arguments |
| `multiple telegram IPAs` / `multiple swiftgram IPAs` | Select the file explicitly; do not assume the script chooses the newest version |
| `engine is not executable` | CLI path, `chmod +x` permissions, and whether the CLI matches your Mac |
| `xcrun` is missing or cannot find Clang | Installation and selection of Xcode tools |
| `image is encrypted` | Use a decrypted IPA; changing the fingerprint cannot fix this |
| `expected a thin ... Mach-O` | Whether the input is a FAT file instead of thin arm64 |
| `only generic arm64 is supported` | The image architecture; arm64e requires separate work |
| `expected one native TL image` / `expected one TelegramCore image` | IPA contents and framework path; a renamed library may require updating the generator's search |
| `unrecognized ...: 0` | No matches: check the input, then changes to code, function boundaries, or fingerprints |
| `ambiguous` or multiple matches | Multiple candidates were found; add evidence that identifies the correct one uniquely |
| `unrecognized Rust ABI/buffer cluster` | The Rust engine or checked function cluster changed; review the ABI |
| `unsupported call count` / `expected one root call` | Changed calls, an additional branch, or compiler inlining |
| `original target` / `import binding` | A changed target function, stub, imported symbol, or library |
| `generated files differ` with `--check` | Reproducible changes exist; compare a run without `--check` and its diff |
| `stale C payload` / `stale ... metadata` | Rebuild with `Tools/build_payloads.py`, then review the changes |
| `Swift witness adapter must remain exactly 20 bytes` | The Pro adapter or compiler output changed; inspect its instructions and insertion contract |
| `arm64 branch is out of range` | The adapter is too far from the branch site; review placement and relocations |
| Planning succeeds but the app crashes | Register preservation, stack handling, memory ownership, signing, and the actual execution path on the device |

For recognition errors, first rule out an incorrect input file. Then compare the
old and new code. Neither a version number nor a matching function name proves
that the ABI is unchanged.

## ARM64 basics for reading patches

### Registers and memory

A register is a small storage location inside the processor. ARM64
general-purpose registers are named `x0`–`x30` and hold 64 bits. The names
`w0`–`w30` refer to the lower 32 bits of the same registers. Writing to `w0`
clears the upper 32 bits of `x0`: replacing `x0` with `w0` can change an
operation's meaning.

These roles are useful when reading the patches:

| Register | What to look for |
| --- | --- |
| `x0`–`x7` | The first simple integer arguments in the ordinary C ABI; `x0` often holds the result |
| `x8` | May hold an indirect result address; on entry to the reviewed Pro witness, it points to the output value |
| `x19`–`x28` | Preserved registers in the ordinary ABI; an insertion must preserve values needed by the surrounding code |
| `x20` | May hold `swiftself`, the Swift call context |
| `x21` | Used for `swifterror`, the error state, in the reviewed Swift adapters |
| `x29` | Usually the current stack frame pointer |
| `x30`, or `lr` | The return address after a call |
| `sp` | The stack pointer |
| `xzr` / `wzr` | Read as zero |

These are starting points, not a complete signature for an arbitrary Swift
function. Arguments may travel through the stack, multiple registers, pointers,
and separate floating-point registers. General ABI register roles are described
in the [Arm AAPCS64 standard](https://github.com/ARM-software/abi-aa/blob/main/aapcs64/aapcs64.rst).
Apple documents its [ARM64 ABI additions](https://developer.apple.com/documentation/xcode/writing-arm64-code-for-apple-platforms).

An **ABI**, or Application Binary Interface, defines how compiled code
interacts: where arguments and results go, which registers are preserved, how
objects are represented, and who frees memory. Matching function names and
sizes is insufficient to establish these rules. Swift-specific behavior is
discussed in the [Swift calling convention document](https://github.com/swiftlang/swift/blob/main/docs/ABI/CallingConvention.rst).

### A minimal instruction set

In these examples, the first operand usually names the destination. A `#`
before a number means an immediate numeric value.

| Instruction | Meaning |
| --- | --- |
| `mov x0, x1` | Copy the value of `x1` into `x0` |
| `mov x8, #2` | Put the number 2 in `x8` |
| `ldr x0, [x19]` | Read 8 bytes from the address held in `x19` into `x0` |
| `str x0, [x19]` | Write 8 bytes from `x0` to the address held in `x19` |
| `ldr w0, [x19, #8]` | Read 4 bytes from address `x19 + 8` |
| `stp` / `ldp` | Store / load a pair of registers |
| `add` / `sub` | Add / subtract; often used for stack management |
| `cmp x0, x8` | Compare the values and record the comparison in processor flags |
| `cbz x21, target` | Branch to `target` if `x21` is zero |
| `cbnz x21, target` | Branch if `x21` is nonzero |
| `tbz` / `tbnz` | Branch based on the value of a particular bit |
| `csel x0, x0, x8, ge` | Select the previous `x0` if the preceding comparison was signed greater than or equal; otherwise select `x8` |
| `b target` | Branch without changing the return address |
| `bl target` | Call code, saving the next instruction's address in `x30` |
| `blr x16` | Call code at the address in `x16`, saving the return address |
| `ret` | Return to the address in `x30` |
| `adrp` followed by `add` or `ldr` | Often used to form a data address or access data |

`b` and `bl` have different meanings. When an insertion continues an existing
function, unnecessarily changing `x30` can break the return path. An adapter
ending with `b Original` can hand control to the original function while
retaining the original caller's return address; this is a tail branch.

Conditions such as `ge` and `lt` are used for signed comparisons. Unsigned
comparisons use different conditions. For example, the Pro adapter handles
`Int64`, so choosing a signed comparison matters for negative values. Instruction
descriptions are available in the [Arm A64 guide](https://developer.arm.com/documentation/102374/latest/).

### Addresses and offsets

Code often uses hexadecimal numbers: `0x18` is 24 and `0x1c` is 28. In JSON,
the number `24` without a prefix is normally written in decimal.

One A64 machine instruction occupies **4 bytes**. Offset `+24` means six
instructions from a function's beginning. This applies to an instruction
sequence; it does not mean that all file data should be divided into four-byte
units.

Distinguish between:

- **VA**: the virtual address in the image, as shown by the disassembler;
- **file offset**: a byte's position inside the Mach-O file;
- **function-relative offset**: the distance from a function's beginning to an instruction;
- **address in a running process**: this can differ because of ASLR.

For a location within a segment's file-backed portion:

```text
file_offset = segment.fileoff + (VA - segment.vmaddr)
```

You cannot use a VA directly as a byte position in a file editor. Zero-fill
regions may have memory addresses without corresponding bytes in the file.
The project utilities use `MachO.offset()` for address conversion.

### Function fingerprints

A **fingerprint** is a hash of a function's instructions after a particular
normalization process. Normalization removes some differences caused by code
and data moving between builds. It retains the differences the algorithm treats
as significant. Moving addresses can therefore remain compatible with an
existing profile, while changing one constant can require a new profile.

The project uses different kinds of hashes:

| Kind | Where it is used |
| --- | --- |
| SHA-256 of an entire archive or file | Identifying the exact input; also protecting a specific file after engine planning |
| Legacy review fingerprint, `MachO.fingerprint()` | Accepting reviewed input code in the Native TL and Rust generators |
| `arm64-reloc-v1`, `MachO.portable_fingerprint()` | Portable engine checks; also the reviewed checks for Secret Chats |

These values are not interchangeable. An ordinary `shasum` result cannot replace
`arm64-reloc-v1`, and a legacy review hash cannot simply be labeled with the new
algorithm's name.

### Anchors and relocations

An **anchor** is a named location found by the engine. For example, `decode`
may identify a decoding function, while `original.delete` identifies a reviewed
original deletion function. `offset_bytes` specifies an offset from that point.

A **relocation** tells the engine how to insert an address after placing an
adapter. For example, the source profile may contain a placeholder `b`
instruction, and the engine computes its final branch distance when applying
the patch. Branch bytes copied from one build can point to the wrong address
in another.

## Finding code in a new version

Use this section when automatic updating stops because code changed. Start by
examining the old supported IPA, where the patch's purpose and reviewed
functions are already known. Then compare the corresponding code in the new
version.

### Extract files for inspection

Create a workspace outside Git, for example in the macOS temporary directory:

```sh
PATCH_REVIEW_DIR="$(mktemp -d "${TMPDIR:-/tmp}/tgextra-review.XXXXXX")"
export PATCH_REVIEW_DIR
mkdir -p "$PATCH_REVIEW_DIR/old" "$PATCH_REVIEW_DIR/new"
unzip -q packages/Telegram_v13.2.1.ipa -d "$PATCH_REVIEW_DIR/old"
unzip -q packages/Telegram_new.ipa -d "$PATCH_REVIEW_DIR/new"
```

This example uses Telegram. For Swiftgram, use its old and new IPAs in a
separate workspace. Here, `$(...)` captures the path returned by `mktemp`;
the original IPAs remain in place.

Find the relevant file:

```sh
rg --files "$PATCH_REVIEW_DIR/new/Payload" \
  | rg 'TelegramCoreFramework.framework/TelegramCoreFramework$'
```

The Native TL and Secret Chats generators currently expect this particular
framework. The Rust generator searches for a suitable image using engine
characteristics; the framework name alone does not establish whether it
contains Rust.

Set the full path, substituting the actual `.app` name:

```sh
PATCH_REVIEW_BINARY="$PATCH_REVIEW_DIR/new/Payload/Telegram.app/Frameworks/TelegramCoreFramework.framework/TelegramCoreFramework"
file "$PATCH_REVIEW_BINARY"
xcrun lipo -info "$PATCH_REVIEW_BINARY"
xcrun otool -l "$PATCH_REVIEW_BINARY" > "$PATCH_REVIEW_DIR/load-commands.txt"
```

In `load-commands.txt`, inspect the architecture and `LC_ENCRYPTION_INFO` /
`LC_ENCRYPTION_INFO_64` commands, if present. A nonzero `cryptid` indicates an
encrypted image. The generators also check this themselves.

### Get the instruction listing

For a thin arm64 Mach-O:

```sh
xcrun llvm-objdump --disassemble "$PATCH_REVIEW_BINARY" \
  > "$PATCH_REVIEW_DIR/new-disassembly.txt"
```

Alternatively, use `otool`:

```sh
xcrun otool -arch arm64 -tvV "$PATCH_REVIEW_BINARY" \
  > "$PATCH_REVIEW_DIR/new-disassembly.txt"
```

Produce `old-disassembly.txt` from the old file in the same way. If you know
the start and end VAs of the relevant range, limit LLVM's output:

```sh
xcrun llvm-objdump --disassemble \
  --start-address=0x100001000 --stop-address=0x100001100 \
  "$PATCH_REVIEW_BINARY"
```

The addresses in this command are **examples only**. Replace them with the
addresses of the function you are investigating. The upper bound is exclusive.
See the [llvm-objdump documentation](https://llvm.org/docs/CommandGuide/llvm-objdump.html)
for the command options.

### Find the corresponding function

First identify which generator check failed. For example, a `native TL
constructor` error points to `REVIEWED['constructor']` in
`Tools/prepare_native_tl.py`. For the old IPA, the existing generator can
uniquely identify that function and its call sites.

In the new version, find a candidate using several clues:

1. Retained symbols or Swift type metadata, if available.
2. Distinctive strings used by the function and code references to them.
3. Functions that call it and functions it calls.
4. Its sequence of checks, field access, and error handling.

For example, the Rust generator uses the marker
`[MTProtoRust] mt_engine_create failed` and checks session initialization.
Pro is found through `TelegramUIPreferences.SGStatus` metadata and its
`Swift.Decodable` conformance. These clues help locate a candidate, but do
not replace instruction and ABI review.

Missing function names are normal: release builds often strip symbols.
Finding a string with `strings` alone does not identify the function using it;
you need a reference to the string from code. For complex cases, a disassembler
with cross-references and a decompiler can help. Pseudocode helps explain the
purpose, but verify registers and insertion points against the actual
instructions.

### Compare behavior and ABI

Make a small table for each changed function:

| Question | What to record |
| --- | --- |
| What does the function do | For example, incoming message deletion rather than arbitrary deletion |
| Where does it begin and end | VAs and size in bytes; whether it has multiple exits |
| Where are the arguments | Registers, stack, account context, transaction pointer |
| Where does the original call go | A reviewed function or a specific import and library |
| How is the result returned | A value, indirect write, optional, error state |
| Who owns the memory | Who retains, copies, and frees objects or buffers |
| What does the patch change | The exact instruction and expected behavior |
| What does the adapter preserve | Required registers, stack, original call, and error path |

Equal function sizes do not establish equal behavior. A changed size does not
necessarily mean the ABI changed, but it requires reviewing the relevant
execution paths. If new calls appear, understand their purpose before changing
the expected call count.

If you cannot yet explain where the arguments are or where control returns,
save the disassembly, IPA details, and your observations for a developer familiar
with ARM64. Verifying these points is a required part of a manual update.

### Compute the reviewed function's fingerprint

After reviewing the code, compute both fingerprint types using the project tools:

```sh
python3 - "$PATCH_REVIEW_BINARY" 0x100001000 0x100001100 <<'PY'
import json
from pathlib import Path
import sys

sys.path.insert(0, str(Path('Tools/RustBridge').resolve()))
from macho import MachO

image = MachO(Path(sys.argv[1]).read_bytes())
start, end = (int(value, 0) for value in sys.argv[2:4])
assert start < end and (end - start) % 4 == 0
assert image.function(start) == (start, end), 'Check the function boundaries'
print('review:', image.fingerprint(start, end))
print('portable:', json.dumps(image.portable_fingerprint(start, end), indent=2))
PY
```

These VAs are examples again. Use the actual boundaries in the project's
`MachO` model. The `function()` method uses the Mach-O function-start table;
do not arbitrarily shorten a range to make it match.

This command **does not write to profiles**. It only computes values for code
you have already reviewed. Whether to accept a new fingerprint depends on the
review of the function, its calls, and its ABI.

## Updating each patch family

The direct generators below are intended for investigating individual families.
Unlike the combined `update_patches.py`, they may write files as they run.
Use your prepared branch and inspect the diff even after a failure.

### Native TL Decoder

Sources and checks:

- `Tools/prepare_native_tl.py`, its `REVIEWED` table, and `identify()` function;
- `Patches/native-tl-v1/payloads/constructor.c` and `result.c`;
- `Sources/tgapiC/NativeTLProfile.inc` and the Native TL code in `Sources/tgapiC`.

Four functions are checked: `constructor`, `body`, `result`, and `topLevel`.
Verify both the parsers themselves and their positions within the reviewed
function cluster. One constructor call from the top-level Swift wrapper and
one function-result call are redirected; recursive native calls must not
accidentally be intercepted in the same way.

For compatible code:

```sh
python3 Tools/prepare_native_tl.py packages/Telegram_new.ipa
python3 Tools/prepare_native_tl.py packages/Swiftgram_new.ipa --check
```

The first command generates the profile and runtime matcher. The second checks
that the same result also fits Swiftgram. If the other client produces a
different result, repeatedly overwriting the shared files does not provide
support for both clients.

When code changes, first review parser signatures and object ownership rules,
then update the reviewed data and generator. Supporting several different
implementations simultaneously requires extending the profile representation
and runtime matcher; the current table is not an automatic list of all versions.

Message field policies live in `Sources/tgapi/TL/MessagePatches.swift`. Updating
parser addresses does not require moving those policies into machine code.

Rebuild the TGExtra DEB after changing `NativeTLProfile.inc`.

### Rust MTProto Bridge

Sources and checks:

- `Tools/RustBridge/abi5.json`: reviewed function characteristics;
- `Tools/prepare_rust_patch.py`: recognition and integration checks;
- `Tools/RustBridge/portable.py`: portable profile generation;
- `Sources/tgapi/RustBridge.h` and `.m`: the runtime contract and implementation;
- the [Rust bridge description](../Tools/RustBridge/README.md).

Current profiles target the Rust engine's **C ABI 5**. Checks also cover the
request ID allocator, buffer operations, session initialization, context
bindings, and expected calls. A change in session lifetime or buffer ownership
can cause a delayed failure even if a simple request sends successfully.

For a compatible client:

```sh
python3 Tools/prepare_rust_patch.py \
  packages/Telegram_new.ipa packages/Telegram-rust.ipatch \
  --patch-set-dir Patches \
  --engine "$IPATCH_ENGINE_CLI" \
  --plan-file packages/Telegram-rust-plan.json
```

Repeat for Swiftgram with its filenames. These standalone Rust archives are
for bridge validation; build the complete TGExtra package through
`package_ipatch.py` with the DEB and all profiles.

The profile directory ID is derived from the profile and payload contents.
Do not derive it from the IPA hash or rename it manually. Differences between
Telegram's and Swiftgram's conservative fingerprints can require separate
profiles even when the ABI is the same.

The Rust README documents an example: four global stores inside `engineCreate`
use page offset `0xb8` in Telegram and `0x4b8` in Swiftgram. Accepting the second
variant was based on reviewing the corresponding `ADRP` instructions, loads,
stores, and branches. It does not establish that arbitrary changed offsets
can be ignored.

If the ABI has actually changed, adding a new hash to `abi5.json` is insufficient.
Review and, where necessary, change the adapters, signatures, runtime, and how
the generator represents the new ABI. One similar fragment does not establish
that an unknown ABI is compatible with ABI 5.

### Secret Chat Protection

Sources and checks:

- `Tools/SecretChats/reviewed.json`: fingerprints, call offsets, and original-target proofs;
- `Tools/prepare_secret_chats.py`: input validation and the `GATES` table;
- `Tools/SecretChats/gate.c.in`: the template for register preservation and callback invocation;
- `Sources/tgapi/SecretChatPolicy.swift` and related handlers.

The five interception sites cover screenshot reporting, incoming deletion,
incoming history clearing, expiry lookup, and media-consumption lookup.
Confirm that these are the intended operations: the user's own local deletion
must remain available.

For compatible clients:

```sh
python3 Tools/prepare_secret_chats.py \
  --telegram packages/Telegram_new.ipa \
  --swiftgram packages/Swiftgram_new.ipa
python3 Tools/build_payloads.py
```

For each manually updated call, check:

1. The containing function and the call's new offset.
2. The branch type, `b` or `bl`, and its original target.
3. The original function's fingerprint or the exact import-stub bytes.
4. For a stub, the real chained binding, symbol name, and library install name.
5. Argument locations, including the transaction, message IDs, and identity fields.
6. Behavior when blocking the operation and when the TGExtra callback is absent.

The caller can remain unchanged while an import binding changes. Matching the
caller's fingerprint alone is therefore insufficient. A changed GOT ordinal
also requires checking the actual binding.

The template preserves `x0`–`x8`, `x20`, `x21`, and its other saved registers,
and restores the stack before calling the original implementation. Offsets in
`[sp, #...]` depend on the layout of the saved values. Changing that layout's
size may also require updating the argument extraction table.

Edit `gate.c.in` and the `GATES` table, then run `build_payloads.py`. Changes
made only to generated `payloads/*.c` files will be overwritten.
`build_payloads.py --check` also verifies that those C files are current.

Blocking incoming deletion must preserve processing and acknowledgment of
incoming operations. Timer protection needs exact message tracking and later
cleanup after protection is disabled. Simply removing a call can break these
requirements.

### Swiftgram Pro

This profile has no generator that updates changed host code. The combined
updater only rebuilds the existing adapter and checks the existing profile
with Pro enabled through the engine.

Sources and checks:

- `Patches/swiftgram-pro-status-v1/patch.json`;
- `Patches/swiftgram-pro-status-v1/payloads/status.c`;
- `Tests/swiftgram_pro_ipatch.py`.

The profile looks for the nongeneric `TelegramUIPreferences.SGStatus` struct
with exactly one mutable `status: Swift.Int64` field, then a unique unconditional
`Swift.Decodable` conformance and its `init(from:)` witness. A **witness** here
is the function through which the type implements a protocol requirement.

It then checks fingerprints for the 40-byte witness and 268-byte decoder body.
In the reviewed version, the original decoder is called at `+16`, the error
check is at `+20`, the result is stored at `+24`, and the shared function
epilogue begins at `+28`.

The relevant part of the original control flow is:

```asm
mov  x19, x8          // save the output value's address
bl   decodeBody      // get status in x0 and error state in x21
cbnz x21, epilogue   // skip the result store on error
str  x0, [x19]       // store status on success
epilogue:
                     // restore saved registers and return
```

These comments describe the reviewed function; they do not define the behavior
of every Swift decoder. The patch replaces only `str x0, [x19]` with a branch
to the adapter:

```asm
mov  x8, #2
cmp  x0, x8
csel x0, x0, x8, ge
str  x0, [x19]
b    epilogue
```

This stores signed `max(2, status)`. The engine links the last branch to
`decode + 28` through a relocation. The C source contains `b .` as a placeholder
there; the engine replaces that branch when linking the final patch. Do not
insert the raw 20 bytes into an IPA without resolving that relocation.

Examples after successful decoding:

| Input status | Stored status |
| --- | --- |
| `-1` | `2` |
| `0` | `2` |
| `1` | `2` |
| `2` | `2` |
| `5` | `5` |

On a decoding error, the result store must remain skipped. Replacing the
decoder call with an unconditional return of 2 would lose this behavior.

For a new version, recheck the field type, conformance metadata, successful
store location, values in `x0`, `x19`, and `x21`, whether `x8` can be used,
the epilogue location, and stack preservation. If the layout changes, the old
`+24`, `+28`, 20-byte payload size, and checked function sizes do not
automatically remain correct.

The adapter is inserted inside an existing Swift function. An ordinary C
function introduces its own stack and return handling. This insertion therefore
uses `__attribute__((naked))` and explicit instructions. Changing it requires
a corresponding test of the ABI and error path.

When adding support for a new implementation while retaining the old one,
create a separate reviewed variant or profile with distinguishable matching
conditions. Check that the engine does not apply two alternative implementations
to the same location under the `all_matching` policy.

Validate Pro against the selected IPA:

```sh
IPATCH_ENGINE_CLI="$IPATCH_ENGINE_CLI" \
SWIFTGRAM_REFERENCE_IPA="$PWD/packages/Swiftgram_new.ipa" \
python3 Tests/swiftgram_pro_ipatch.py
```

The adapter execution test requires Apple Silicon. If the witness changes,
its test image must also match the newly reviewed implementation. Changes to
test expectations must follow from reviewing the code.

The Pro profile changes local Swiftgram behavior. It does not provide Telegram
Premium or server features. Support Swiftgram's author by purchasing Pro
officially.

## Testing on a device

A successful plan establishes that structural checks match and edits can be
constructed. Testing on an iPhone is needed to verify behavior in the real
client. A dedicated test chat and a second account or device help compare
behavior between participants.

Record the client version, build number, iOS version, device model, TGExtra
commit, DEB variant, and whether Pro is enabled. Fully restart the application
after installation. Open **Settings → TGExtra → Message Data → Debug Log**
and save the schema, hook, and callback status.

| Area | What to test |
| --- | --- |
| Basic operation | Launching, receiving and sending messages, switching accounts, and relaunching |
| Native TL | Ordinary responses and updates, the affected policies, and integration status in the log |
| Rust | Requests, ghost mode, media transfers, protected-forward recovery, and operation after switching accounts |
| Secret-chat screenshots | The screenshot is captured and, with protection enabled, the other participant receives no notification |
| Incoming deletion | Individual deletion and history clearing by the other participant; messages and markers are retained |
| Local deletion | The user's own deletion and history clearing still work |
| Timers | Expiry with protection enabled; after disabling it, cleanup for the active account within the roughly 30-second cycle; repeat after a restart |
| Media consumption | Disappearing photo and video behavior and saving with the relevant settings |
| Pro | Compare two IPAs built from the same original, with Pro disabled and enabled; initialize a new account's status through an online launch |

Also test each feature with its setting disabled: behavior should depend on
the setting wherever intended. For privacy features, observing the other
participant's side provides more evidence than a button's state on your screen.

If the app crashes, save the crash log, Debug Log, and exact reproduction steps.
If a simple scenario never calls a function, the absence of a crash does not
test its adapter. To return to a previous build, use the previously reviewed
sources, matching DEB, and original IPA; do not apply an old package over an
already modified IPA.

## What to commit

Before committing:

```sh
git status --short
git diff --check
git diff --stat
```

Changes usually include profile JSON and C sources and, where needed,
generators, reviewed data, the runtime matcher, runtime code, and tests.
Generated `.bin` files are ignored: the release build regenerates them.

Do not add IPAs, DEBs, local plans, or extracted applications. Stage explicit
paths for the changes you reviewed. Keep old Rust profiles when their support
is still claimed.

In the change description, record:

- Exact versions, build numbers, and bundle IDs of the new clients.
- Which families were validated and where code or ABI changes were needed.
- Why the new fingerprints and offsets identify the intended functions.
- Results of tests, planning, and application to the new IPA.
- Device testing performed, including settings and accounts.
- Checks that were skipped and compatibility retained with older builds.

Update supported-build details in the main README and the
[technical profile documentation](README.md). Adding an IPA to the reference
list must be backed by actual validation of that build.

## Quick reference

The normal cycle when the code remains compatible:

```sh
export IPATCH_ENGINE_CLI="$HOME/Tools/ipatch"

python3 Tools/update_patches.py \
  --telegram packages/Telegram_new.ipa \
  --swiftgram packages/Swiftgram_new.ipa \
  --engine "$IPATCH_ENGINE_CLI"

git diff -- Patches Sources/tgapiC/NativeTLProfile.inc

python3 Tools/update_patches.py \
  --telegram packages/Telegram_new.ipa \
  --swiftgram packages/Swiftgram_new.ipa \
  --engine "$IPATCH_ENGINE_CLI" --check

export SWIFTGRAM_REFERENCE_IPA="$PWD/packages/Swiftgram_new.ipa"
bash Tests/run.sh
```

Then build the ipatch with the matching DEB, validate the complete package on
both new IPAs, explicitly enable Pro for its validation, apply the patches to
copies, and run the device scenarios. If code recognition fails, return to the
review for that patch family before continuing the build.
