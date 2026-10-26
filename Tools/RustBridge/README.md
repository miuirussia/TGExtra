The bridge targets C ABI 5 of TelegramMessenger/mtproto-engine, pinned by
Telegram-iOS 1dd3e7f4ed to da4b2170210aab0430c4ff18c032991f3030cf45.

The offline generator identifies reviewed function bodies by normalized arm64
instruction fingerprints, derives all addresses from the input Mach-O and checks
call targets, the ABI marker and the Rust session's usage-manager and context lookup call sites.
It supports renamed/relinked clients such as Swiftgram when they contain the
same reviewed Rust engine. Unrecognized machine code fails closed. Clients
without Rust keep the existing MtProtoKit hooks.

No application bundle ID, framework name, UUID or file offset is used for source
recognition. The generator now emits ipatch v2 profiles with engine-specific
`arm64-reloc-v1` fingerprints, counted calls, relocatable payloads and generated
metadata. The old review fingerprints in `abi5.json` remain separate and gate
which input code may produce a new profile. The engine can reuse a profile for
other builds only when all its structural checks match. The profile's explicit
bundle IDs still constrain selection. Use `--patch-set-dir Patches` to include
a profile in future GitHub releases. See [Patches/README.md](../../Patches/README.md)
for engine requirements, validation, offline application and v1 migration.

The reviewed references are Telegram 13.1.1 (35634) and Swiftgram 13.1.1 (343,
`app.swiftgram.ios`). Swiftgram's 4640-byte `engineCreate` body has four additional
link-time differences retained by the review fingerprint: stores at body offsets
`0x11c4`, `0x11e0`, `0x11e8` and `0x11f0` use the relocated global's page offset
`0xcb8` instead of `0x860`. Disassembly confirms that each store uses the same
global as its preceding ADRP/load pair across a conditional branch. All other
normalized instructions and reviewed Rust function fingerprints match Telegram.
`abi5.json` lists this constructor hash as an explicit reviewed variant; unknown
hashes and multiple matching constructors remain rejected. Portable engine
fingerprints stay conservative, so each client has a separate generated profile.

Protected-forward recovery shares ForwardCopy's journal/transfer state machine.
A request-service adapter sends its helpers through the active Rust session with
IDs from the native atomic allocator; foreign-DC media workers use the bound
MTContext. Helper replies update the host's liveness bookkeeping without entering
its RPC parser. Synthetic completion buffers implement the same no-copy ownership
contract through the data/length/free thunks. Cancellation, session teardown and
deferred dependent requests are synchronized with helper submission.

Regenerate archives produced before recovery was added. New metadata includes
BufferFree, NextRequestID, Send and Cancel, and the offline patch adds a context
lookup thunk. Older metadata retains ordinary TL transformations but cannot
start protected-forward recovery.
