# Archived v1 Rust patch

This directory preserves the hash-pinned Telegram 13.1.1 (35634) patch and its
original metadata for engines that support only ipatch v1.

Normal releases package Patches/, which contains portable v2 profiles. Do not
combine this legacy bridge with a matching portable bridge in one package:
both sets could select and conflict on code or TGExtraRustBridge.plist.

The IPA release workflow passes --retire-patches PatchesV1 when merging a v2
update into an old release. Only these exact legacy identities are retired,
and only when portable profiles cover their bundle IDs.

See Patches/README.md for packaging and migration commands.
