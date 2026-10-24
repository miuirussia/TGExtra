Client patch sets included in every GitHub ipatch release live in separate folders:

```
Patches/<set-id>/patch.json
Patches/<set-id>/resources/<client-specific resources>
```

`patch.json` contains `name`, required `bundle_ids`, `binary_patches` and optional
`resources`. Each edit uses `target: {"type": "offset", "offset": ...}` with a
full-file SHA-256 on its binary. Resource sources are relative to the set folder;
destinations are relative to the app. The bundle ID and all original binary
digests must match for a set to apply. Several independent sets can apply to one
client. There is no fixed set-count limit; archive,
manifest and replaced-byte size limits still apply. Unmatched resources are
never installed, so clients can use the same metadata filenames.

To add a reviewed Rust client/build:

```sh
python3 Tools/prepare_rust_patch.py Client.ipa Client.ipatch --patch-set-dir Patches
```

Commit the resulting folder. GitHub builds include every set automatically.
The IPA workflow also generates a set from its input IPA and merges it into the
release's ipatch for every DEB, preserving the other clients and the DEB embedded
in each variant. The archive has a root `manifest.json` with `format: "ipatch"`
and `version: 1`; no cyan config or executable is needed. Clients without Rust
produce no ipatch and keep the existing MtProtoKit hooks.
