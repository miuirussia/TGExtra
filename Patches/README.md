Client patch sets included in every GitHub cyan release live in separate folders:

```
Patches/<set-id>/patch.json
Patches/<set-id>/inject/<client-specific resources>
```

`patch.json` supports `name`, optional `bundle_ids`, `binary_patches` and `f`.
All original binary digests must match for a set to apply. Several independent
sets can apply to one client. There is no fixed set-count limit; archive,
manifest and replaced-byte size limits still apply. Unmatched resources are
never installed, so clients can use the same metadata filenames.

To add a reviewed Rust client/build:

```sh
python3 Tools/prepare_rust_patch.py Client.ipa Client.cyan --patch-set-dir Patches
```

Commit the resulting folder. GitHub builds include every set automatically.
The IPA workflow also generates a set from its input IPA and merges it into the
release's universal cyan, preserving the other clients and the tweak package.
