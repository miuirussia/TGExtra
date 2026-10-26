# Portable client profiles and optional features

Client profiles included in every GitHub ipatch release live in separate folders:

~~~text
Patches/<profile-id>/patch.json
Patches/<profile-id>/payloads/<bridge-name>.bin
~~~

Each patch.json contains name, required bundle_ids and binary_patches with a
portable profile. `features.json` declares the optional iPatch v3 components;
a set's `feature` binds it to a declaration. Sets without `feature` remain
mandatory base functionality. Payload sources are relative to the profile
folder. Packaging rebases them under the archive's payloads/ root.

For the Rust bridge, the engine discovers exactly one
compatible Mach-O, validates functions and call counts, allocates header padding,
links the payloads and generates TGExtraRustBridge.plist from that image's UUID
and function offsets. No compatibility SHA-256, fixed framework path or copied
metadata is needed. The engine still captures a full-file digest and exact
preimages to protect application after planning.

## Swiftgram Pro feature

`swiftgram-pro` is disabled by default. Select it using the gear beside the
uploaded ipatch in iOSPatchingEngine. The corresponding set contains only binary
edits and a 20-byte arm64 payload; the TGExtra DEB contains no Pro implementation,
preference or menu item. Disabling it requires rebuilding the original IPA with
the feature off. The feature does not require the TGExtra runtime to execute.

`swiftgram-pro-status-v1/patch.json` uses v3 Swift metadata anchors to require:

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
`payloads/status.s` is the reviewable source; the native test checks that assembly
matches the shipped bytes and exercises both success and error paths.

The reviewed reference is Swiftgram 13.1.1 (343, `app.swiftgram.ios`), generic
arm64. V3 engine planning has been checked against that decrypted IPA. The type
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
The committed portable profiles have been checked on Telegram 13.1.1 (35634) and
Swiftgram 13.1.1 (343, app.swiftgram.ios), including engine planning and application
to extracted copies of both clients. Swiftgram needs its own profile because its
engine constructor and session initializer have different conservative
fingerprints. These checks do not replace on-device validation.

The bridge targets C ABI 5 of TelegramMessenger/mtproto-engine, pinned by
Telegram-iOS 1dd3e7f4ed to da4b2170210aab0430c4ff18c032991f3030cf45.
Profile generation currently accepts unencrypted thin generic arm64 reference
images. The engine can apply these Rust profiles to a generic arm64 slice in
a thin or FAT input. These profiles do not target arm64e.

## Engine validation and application

Build the CLI from iOSPatchingEngine's server directory (v3 for release packages
with optional features; v2 is sufficient for standalone Rust-only profiles):

~~~sh
go build -o /path/to/ipatch ./cmd/ipatch
~~~

The engine must include the zero-fill data-reference fingerprint fix in
Tools/iOSPatchingEngine-v2.patch. Real Rust engineCreate code references
zero-fill globals; those are valid normalization targets, while patch writes
must still target file-backed bytes.

~~~sh
python3 Tools/prepare_rust_patch.py Client.ipa Client.ipatch --patch-set-dir Patches --engine /path/to/ipatch --plan-file plan.json
~~~

The --engine option validates the package through the engine's actual dry-run
planner. With --apply-app Client.app, the generator applies that plan's verified
edits and generated metadata to an extracted copy. The input IPA is never modified.

Without --engine, --apply-app retains the standalone offline application path:
it derives hash-pinned edits and metadata for the exact input and applies them
locally. The exported release archive still uses portable v2 operations. The IPA
workflow uses this path so it does not require access to a private engine checkout.
Both paths use the same reviewed bridge code; their allocation addresses can
differ. Modified binaries still need signing.

## Packaging and migration

~~~sh
python3 Tools/package_ipatch.py --deb TGExtra.deb --patches Patches --output TGExtra.ipatch
~~~

Every DEB variant embeds its matching DEB and all committed portable profiles in
a version 3 archive, including declarations from `features.json`. Payload files
are included automatically. Base Rust sets install the DEB; the Pro feature set
does not reference or depend on it. The packager also accepts v1/v2 archives and
preserves feature declarations, other client sets and the embedded DEB when
merging an update. A v2 update cannot downgrade an existing v3 archive.
Profiles with the same feature, original anchors and checks are replaced on
update, preserving their combined explicit bundle IDs; distinct compatibility
profiles remain separate. Conflicting feature declarations are rejected.

The previous hash-pinned Telegram set is retained separately in PatchesV1/.
It is excluded from portable release packages to avoid selecting two different
bridges and metadata resources for the same original binary. It can still be
packaged for a v1 engine:

~~~sh
python3 Tools/package_ipatch.py --deb TGExtra.deb --patches PatchesV1 --output TGExtra-v1.ipatch
~~~

When migrating an existing release archive, explicitly retire those exact
archived legacy set identities:

~~~sh
python3 Tools/package_ipatch.py --base TGExtra-old.ipatch --merge Client.ipatch --retire-patches PatchesV1 --output TGExtra.ipatch
~~~

Retirement requires portable profiles for the retired sets' bundle IDs. Other
legacy clients are retained. Additional overlapping legacy profiles require
their own verified migration; the engine rejects conflicts instead of choosing
one set by order. The generator's --legacy option remains available to create
a new hash-pinned v1 package explicitly.

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
convention on Apple Silicon. With a v3 CLI and a compatible reference IPA it also
checks default-off, explicit off/on selection and the resolved binary edits.

On Apple Silicon macOS the Rust test builds two native layouts, asks the engine to
allocate/link production thunk templates, compares the linked bytes with the
original generator and executes Objective-C argument, return, original-call and
missing-tweak fallback checks. It also checks fingerprint semantics. Native
engine execution is skipped if the CLI or platform is unavailable. Device
validation of the full Telegram/Rust integration is still required.
