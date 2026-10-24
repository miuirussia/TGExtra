The bridge targets C ABI 5 of TelegramMessenger/mtproto-engine, pinned by
Telegram-iOS 1dd3e7f4ed to da4b2170210aab0430c4ff18c032991f3030cf45.

The offline generator identifies reviewed function bodies by normalized arm64
instruction fingerprints, derives all addresses from the input Mach-O and checks
call targets, the ABI marker and the Rust session's usage-manager and context lookup call sites.
It supports renamed/relinked clients such as Swiftgram when they contain the
same reviewed Rust engine. Unrecognized machine code fails closed. Clients
without Rust keep the existing MtProtoKit hooks.

No application bundle ID, framework name, UUID or file offset is used for
recognition. Each generated set pins the input SHA-256, exact preimages and
UUID. Generate a set for each different binary; one ipatch can collect all sets
and the engine selects those matching the original application. Use
`--patch-set-dir Patches` to include a set in future GitHub releases.

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
