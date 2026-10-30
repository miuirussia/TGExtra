The bridge targets C ABI 5 of TelegramMessenger/mtproto-engine, pinned by
Telegram-iOS 1dd3e7f4ed to da4b2170210aab0430c4ff18c032991f3030cf45.

The offline generator identifies reviewed function bodies by normalized arm64
instruction fingerprints, derives all addresses from the input Mach-O and checks
call targets, the ABI marker and the Rust session's usage-manager and context lookup call sites.
It supports renamed/relinked clients such as Swiftgram when they contain the
same reviewed Rust engine. Unrecognized machine code fails closed. Clients
without Rust keep the existing MtProtoKit hooks.

No application bundle ID, framework name, UUID or file offset is used for source
recognition. The generator now emits ipatch v4 documents with engine-specific
`arm64-reloc-v1` fingerprints, counted calls, relocatable payloads and generated
metadata. The old review fingerprints in `abi5.json` remain separate and gate
which input code may produce a new profile. The engine can reuse a profile for
other builds only when all its structural checks match. The profile's explicit
bundle IDs still constrain selection. Use `--patch-set-dir Patches` to include
a profile in future GitHub releases. See [Patches/README.md](../../Patches/README.md)
for engine requirements, validation and offline application.

The reviewed references are Telegram 13.1.2 (35638) and Swiftgram 13.1.1 (343/344,
`app.swiftgram.ios`). Their 4640-byte `engineCreate` bodies have four link-time
differences retained by the review fingerprint: stores at body offsets
`0x11c4`, `0x11e0`, `0x11e8` and `0x11f0` use the relocated global's page offset
`0xa18` (Telegram) or `0xcb8` (Swiftgram).
Disassembly confirms that each store uses the same global as its preceding
ADRP/load pair across a conditional branch. All other normalized instructions
and reviewed Rust function fingerprints match between the clients.
`abi5.json` lists Swiftgram's constructor hash as an explicit reviewed variant; unknown
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

Each `Patches/rust-abi5-*/payloads/<name>.c` compiles into an adjacent `<name>.bin`.
Only C sources are versioned; binaries are generated and ignored by Git.
These C sources implement the class lookup, named Objective-C call and
missing-tweak fallback; the Python code no longer hand-encodes their instructions.
`portable.py` emits the initial standalone sources for new profiles, and
`Tools/payloads.py` compiles them and reads their Mach-O relocation tables.
Existing profiles rebuild directly from their adjacent C files:

~~~sh
python3 Tools/build_payloads.py
python3 Tools/build_payloads.py --check
~~~

Both commands require macOS with Apple Clang. Rebuilding updates payload blocks
and their relocations, preserving the reviewed host-code checks. Rust directory
identities change when the generated binary payload changes. The offline patch
path links the same compiled C adapters. `.ipatch` archives include the C sources
beside the binary payloads. See [Patches/README.md](../../Patches/README.md) for
compiler reproducibility and validation requirements.
