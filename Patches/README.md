# Portable client profiles and optional features

Client profiles included in every GitHub ipatch release live in separate folders:

~~~text
Patches/<profile-id>/patch.json
Patches/<profile-id>/payloads/<bridge-name>.c
Patches/<profile-id>/payloads/<bridge-name>.bin  # generated, ignored by Git
~~~

Each `patch.json` is a complete ipatch v4 author document with `components`,
`variants` and flattened `binaries`. All mandatory profiles share the `required`
component, displayed as **TGExtra**, with `match: "all_matching"`, preserving the previous base-group
selection behavior. `swiftgram-pro` is a separate optional component, disabled
by default; its name, description and defaults live in its own document.
Payload sources are relative to the profile folder. Packaging rebases them under
the archive's `payloads/` root.

Display names are **Native TL Decoder**, **Rust MTProto Bridge** and
**Swiftgram Pro**. Rust content hashes remain in profile IDs and directory names
so rebuilding changed payloads still produces a distinct identity.

For the Rust bridge, the engine discovers exactly one
compatible Mach-O, validates functions and call counts, allocates header padding,
links the payloads and generates TGExtraRustBridge.plist from that image's UUID
and function offsets. No compatibility SHA-256, fixed framework path or copied
metadata is needed. The engine still captures a full-file digest and exact
preimages to protect application after planning.

## Payload sources and rebuilding

Only the standalone `.c` sources and profile definitions are versioned; `.bin`
files are generated beside their same-named C sources and ignored by Git. This
includes all ten Rust bridges in each profile. Rust adapters look up
`TGExtraRustBridge`, register their named selector,
and forward the original arguments plus the host function pointer to the class
method. If the class is missing, they call the original host implementation.
The register-sized parameters transport the reviewed generic arm64 ABI; the
request types and ownership contract are in `Sources/tgapi/RustBridge.h`.

On macOS with Apple Clang:

~~~sh
python3 Tools/build_payloads.py
python3 Tools/build_payloads.py --check
~~~

No reference IPA is needed to rebuild existing payloads. The script compiles each
adjacent source, updates block sizes and relocations, and renames Rust profiles
when their binary identity changes. Reviewed anchors and compatibility checks are
preserved. New Rust profiles export standalone C sources automatically; their
initial source template lives in `Tools/RustBridge/portable.py`.

`Tools/payloads.py` reads the compiler's Mach-O relocation tables rather than
inferring instruction locations. Unsupported imports, sections and relocation
forms are rejected. Payloads are compiled for generic arm64 with `-O2`, without
stack-protector or unwind dependencies. Different Clang versions can produce
different code and profile identities. Run the native bridge and engine tests
after rebuilding. `bash Tests/run.sh` rebuilds all payloads automatically, so it
also works in a fresh checkout with no `.bin` files. Before running individual
Python tests or packaging manually, run `python3 Tools/build_payloads.py` first.
The release packager includes the adjacent C sources in `.ipatch` archives too.
GitHub Actions rebuilds payloads from these sources before running checks. It
uploads the tested profiles as `compiled-payloads`; the ipatch job packages that
artifact, including its generated sizes, relocations and Rust profile identities.

## Native TL decoder

`native-tl-v1` accelerates the MtProtoKit response path on the reviewed Telegram
13.1.2 (35638) and Swiftgram 13.1.1 (343/344) generic arm64 engines. The profile checks
the constructor parser, its object-body parser, the function-result parser and
the Swift top-level wrapper. Exactly one constructor call in that wrapper and
one function-result call are redirected. Recursive native calls stay unchanged.

`payloads/constructor.c` and `payloads/result.c` are the compiled bridge sources.
Each resolves the exported TGExtra bridge with `dlsym` and passes it the parser
arguments and original parser address. A missing tweak falls through to the
original parser. TL field offsets and policy conditions stay in the runtime.

The engine generates `TGExtraNativeTL.plist` with the image UUID, parser offsets,
bridge offsets and checked call sites. TGExtra verifies those locations and the
native root-class ABI before using the decoder. DEB installs use the same code
matcher and `MSHookFunction`; unavailable native integration falls back to the
byte codec. Rust responses retain that fallback because their asynchronous
queue boundary needs a separate account-aware integration.

Rules stay in `Sources/tgapi/TL/MessagePatches.swift`; `nativeRules` compiles the
simple named flags into field-index operations. Stateful rules run through lazy
native-backed views and preflight their writes before touching the host objects.
Only successful complete root decodes can publish policy state.

Regenerate or verify the profile and runtime matcher from a reviewed reference:

~~~sh
python3 Tools/prepare_native_tl.py packages/Telegram_v13.1.2.ipa
python3 Tools/prepare_native_tl.py packages/Swiftgram_v13.1.1.ipa --check
IPATCH_ENGINE_CLI=/path/to/ipatch python3 Tests/native_tl_profile.py
~~~

Changed parser code requires a new review. These tests verify both reference IPA
plans and execute the bridges against the fixture engine on macOS; they do not
replace device testing. Native arm64e binary profiles are not currently provided.

## Swiftgram Pro feature

`swiftgram-pro` is disabled by default. Select it using the gear beside the
uploaded ipatch in iOSPatchingEngine. The corresponding set contains only binary
edits and a 20-byte arm64 payload; the TGExtra DEB contains no Pro implementation,
preference or menu item. Disabling it requires rebuilding the original IPA with
the feature off. The feature does not require the TGExtra runtime to execute.

`swiftgram-pro-status-v1/patch.json` uses v4 Swift metadata anchors to require:

- The nongeneric struct `TelegramUIPreferences.SGStatus` with exactly one mutable
  `status: Swift.Int64` field (field flags 2).
- Exactly one unconditional `Swift.Decodable` conformance and its `init(from:)`
  witness, found without exported Swift symbols.
- The reviewed 40-byte witness and 268-byte decoder body, each checked with an
  `arm64-reloc-v1` fingerprint.

The witness preserves the original decoder call and branches around result
storage when Swift's error register x21 is nonzero. The patch redirects only the
successful store at witness +24 to `payloads/status.bin`. That payload computes
signed `max(2, x0)`, stores the value through x19, and returns to the existing
epilogue at +28. The stack, preserved registers and error path are unchanged.
`payloads/status.c` is the reviewable source. It includes the C meaning of the
operation and a five-instruction naked adapter: this insertion uses the enclosing
Swift witness's registers and stack, so an ordinary C function is unsuitable. The
native test checks the compiled adapter against the shipped bytes and exercises
both success and error paths.

The reviewed reference is Swiftgram 13.1.1 (343, `app.swiftgram.ios`), generic
arm64. V4 engine planning has been checked against that decrypted IPA. The type
and code checks permit relinking that preserves those constraints; changed code,
metadata or architecture needs another reviewed profile. No arm64e compatibility
is claimed. Device validation of the complete Pro behavior is still required.
The feature covers local Swiftgram Pro behavior, with the same initial-account
status limitation as the former decoder hook; Telegram Premium and server
services remain separate. We strongly recommend supporting Swiftgram's author
by purchasing Pro officially.

## Generating a profile

~~~sh
python3 Tools/prepare_rust_patch.py Client.ipa Client.ipatch --patch-set-dir Patches
~~~

Commit the resulting folder. Its identity includes the profile and payload
contents, not the input binary hash. Source recognition still uses the reviewed
ABI 5 instruction fingerprints in Tools/RustBridge/abi5.json; unsupported code
is rejected. From that reviewed input the generator computes the engine's more
conservative arm64-reloc-v1 fingerprints, including the session constructor.
The old Python hashes are never relabelled as engine hashes.

One profile can match relinked builds with the same checked code, constructor,
function cluster and call counts. A changed constructor or conservative
fingerprint can require a separate profile even if the Rust ABI is unchanged.
Bundle IDs remain explicit; the generator adds the input client's ID and retains
previously authorized IDs when exporting the same profile again.
The committed portable profiles have been checked on Telegram 13.1.2 (35638) and
Swiftgram 13.1.1 (343/344, app.swiftgram.ios), including engine planning and application
to extracted copies of both clients. Swiftgram needs its own profile because its
engine constructor and session initializer have different conservative
fingerprints. These checks do not replace on-device validation.

Telegram 13.1.2 uses `rust-abi5-76a4cab831e61d6d` with ABI 5. The four reviewed
global stores in `engineCreate` use page offset `0xa18`. The shared native TL
parser profile and Swiftgram Rust profile remain included.

The bridge targets C ABI 5 of TelegramMessenger/mtproto-engine, pinned by
Telegram-iOS 1dd3e7f4ed to da4b2170210aab0430c4ff18c032991f3030cf45.
Profile generation currently accepts unencrypted thin generic arm64 reference
images. The engine can apply these Rust profiles to a generic arm64 slice in
a thin or FAT input. These profiles do not target arm64e.

## Engine validation and application

Build the v4 CLI from iOSPatchingEngine's server directory:

~~~sh
go build -o /path/to/ipatch ./cmd/ipatch
~~~

The engine's fingerprint normalization must support references to zero-fill globals.
Rust engineCreate code references zero-fill globals, which are valid normalization
targets. Patch writes must still target file-backed bytes.

~~~sh
python3 Tools/prepare_rust_patch.py Client.ipa Client.ipatch --patch-set-dir Patches --engine /path/to/ipatch --plan-file plan.json
~~~

The --engine option validates the package through the engine's actual dry-run
planner. With --apply-app Client.app, the generator applies that plan's verified
edits and generated metadata to an extracted copy. The input IPA is never modified.

Without --engine, --apply-app retains the standalone offline application path:
it derives hash-pinned edits and metadata for the exact input and applies them
locally without a private engine checkout. The exported release archive still
uses portable v4 operations.
Both paths use the same reviewed bridge code; their allocation addresses can
differ. Modified binaries still need signing.

## Packaging and migration

~~~sh
python3 Tools/build_payloads.py
python3 Tools/package_ipatch.py --deb TGExtra.deb --patches Patches --output TGExtra.ipatch
~~~

Every DEB variant embeds its matching DEB and all committed profiles in a
version 4 archive. Payload files and their adjacent C sources are included
automatically. Mandatory variants install the DEB; the optional Pro component
does not reference or depend on it. The packager accepts v4 archives for updates
and preserves component metadata, match policies, other client variants and the
embedded DEB. Older archives must be migrated to v4 before merging.
Composable profiles with the same original compatibility proofs are replaced on
update, preserving their combined explicit bundle IDs; distinct profiles remain
separate. Conflicting component definitions and duplicate IDs are rejected.
Exclusive (`exactly_one`) components retain their selection policy and update
variants by ID.

Each source can also be checked and packed directly with the engine:

~~~sh
/path/to/ipatch -check Patches/native-tl-v1/patch.json
/path/to/ipatch -pack Patches/native-tl-v1/patch.json -output NativeTL.ipatch
~~~

The generator's `--legacy` option selects hash-pinned full-file edits instead of
portable operations; both modes emit v4 documents.

Clients without Rust generate no new package and keep existing MtProtoKit hooks.
Protected-forward recovery retains the shared ForwardCopy state machine,
request allocator, buffer ownership and session teardown behavior described in
Tools/RustBridge/README.md.

## Checks

~~~sh
python3 Tests/ipatch_packaging.py
python3 Tests/swiftgram_pro_ipatch.py
IPATCH_ENGINE_CLI=/path/to/ipatch SWIFTGRAM_REFERENCE_IPA=/path/to/Swiftgram.ipa python3 Tests/swiftgram_pro_ipatch.py
IPATCH_ENGINE_CLI=/path/to/ipatch python3 Tests/rust_portable.py
~~~

The Pro test executes the shipped payload against the reviewed witness calling
convention on Apple Silicon. With a v4 CLI and a compatible reference IPA it also
checks default-off, explicit off/on selection and the resolved binary edits.

On Apple Silicon macOS the Rust test builds two native layouts, asks the engine to
allocate/link production thunk templates, compares the linked bytes with the
offline C-payload linker and executes Objective-C argument, return, original-call and
missing-tweak fallback checks. It also checks fingerprint semantics. Native
engine execution is skipped if the CLI or platform is unavailable. Device
validation of the full Telegram/Rust integration is still required.
