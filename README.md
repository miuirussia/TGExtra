# TGExtra
A simple Telegram iOS Tweak.

Open **Settings** in Telegram, scroll to the bottom and tap **TGExtra**.
The entry uses Objective-C AsyncDisplayKit/UIKit hooks checked against Telegram
[`release-13.0.0`](https://github.com/TelegramMessenger/Telegram-iOS/tree/f1dd7a2dbd02cbbf513e75d5695d8d36d1cf5838); it does not
patch Swift methods. It is hidden while editing the profile and is not added to
other people's profiles. The original support action is preserved.
You can also long-press **Ask a Question**, long-press the screen with three
fingers, or tap the Chats tab five times.

## Screenshots

![Screenshot 1](Screenshots/1.png)
![Screenshot 2](Screenshots/2.png)

## Features

- Disable Ads
- Remove iOS content restrictions on channels, users and messages, independently
  of the protected-content forwarding toggle
  - Apple message rules (`appleterms`, `appleterms-ios`) are also added to the
    client's ignored reasons, covering messages already stored in Telegram.
    Restart Telegram after installing the update to refresh this configuration.
- Ghost Mode
- No Read Receipt for messages and Stories
- Ghost exceptions: manage users from their profile or the tweak menu. Exceptions
  apply to typing and read receipts; online status remains hidden globally.
- Save and forward protected content
  - When Telegram rejects a forward with `CHAT_FORWARDS_RESTRICTED`, TGExtra
    sends a new copy through the active transport adapter. Text formatting,
    captions and album grouping are retained; photos, videos, documents, audio
    and voice messages are downloaded and uploaded again. The copy has no
    forwarded-author header. This uses the existing protected-content toggle.
    It does not patch Telegram's Swift code.
  - Copies require access to the original message and media, permission to send
    in the destination, and enough temporary disk space. Files are streamed in
    512 KiB parts, with a 4000-part limit. Polls, stickers, custom emoji media,
    paid/expiring media, rich-message bodies and unsupported forward options
    remain unsupported. Server and transfer errors are reported normally.
- Normalize high-frame-rate videos (including 60 fps video messages and 120 fps
  stories) to H.264/AAC at 30 fps before saving to Photos, preserving duration
  and audio. Works independently of the protected-content bypass.
  Ordinary 24/30 fps videos are unchanged.
  This does not undo slow motion already rendered into a previously saved file.
- Ignore copy protection in private chats, independently of the protected-content
  toggle. Reopen the other person's profile after changing this option to refresh
  cached chat settings. The server-side sharing setting remains unchanged.
- Keep deleted messages and messages with chat auto-delete timers
- Keep edit history, including rich text, formatting and attachment changes; tap the pencil beside a message to view revisions
- Disable screenshot notifications for supported Telegram requests
- View disappearing media without starting its timer, with an optional label
- Video to Voice: send the audio track as a voice message, respecting preview trims
- Fix the Files picker and clear its temporary cache
- Fake location and ten interface languages

The integration bundles a standalone Swift codec generated from the Telegram
13.1 TL schema at [`1dd3e7f4ed`](https://github.com/TelegramMessenger/Telegram-iOS/commit/1dd3e7f4ed5d72caed1caa04033832c28a5920f5).
It supports the host's new channel/profile constructors, wallet cards, share
themes and rich reply quotes. The host now uses an Objective-C TL engine;
TGExtra keeps its own Swift codec to avoid registering duplicate runtime classes.
The replaced Telegram 13.0 constructors remain supported, and network objects
retain their original constructor IDs so the same tweak works with 13.0 and 13.1
hosts. Restored message snapshots upgrade legacy IDs for hosts running 13.1 or later.
Private UI hooks depend on the host app exposing the corresponding methods.
New features default to off; existing preferences are preserved on upgrade.

Protected-copy recovery journals are account-scoped and stored separately in
Application Support/TGExtra/ForwardCopies. They retain the planned requests and
real server acknowledgements, so retries skip confirmed sends, including when
a compact send reply's follow-up lookup failed. Completed journals expire after
seven days; unfinished journals remain for recovery. At most 128 journals are
retained before new copy operations are refused. Temporary media files are
removed after completion/cancellation and stale transfer files are removed when
the next transfer starts. These outgoing recovery journals are separate from
the edit-history/deletion database cleared by the menu.

Telegram 13.1's optional Rust MTProto transport has a separate C ABI bridge.
It applies the same outgoing request policy, app-config/voice rewrites and
incoming TL transformations as MtProtoKit, including account-scoped history
and deletion/timer markers. The bridge preserves Rust's cancellation, retries,
request dependencies and callback context. Suppressed activity is replaced by
`help.getNearestDc`; the real successful completion supplies the expected
synthetic response, so this path still needs a network connection.

Release binaries strip the Rust FFI symbols. The GitHub release cyan includes
all client patch sets under `Patches/`. Updated iOSPatchingEngine selects sets
whose original binary SHA-256 values match the input IPA, with optional bundle
ID filtering. Client-specific metadata is installed only for matched sets.
Multiple independent sets can apply together; conflicting edits fail the job.
There is no fixed number of client sets, binaries or edits. The existing archive,
manifest, binary and replaced-byte size limits still apply.

Generate a standalone patch cyan, optionally exporting its set for future releases:

```sh
python3 Tools/prepare_rust_patch.py Client.ipa TGExtra-Rust.cyan --patch-set-dir Patches
```

The generator derives addresses from reviewed C ABI 5 instruction fingerprints,
without depending on the client bundle ID or framework name. Relinked clients
such as Swiftgram can use the same generator when they contain the reviewed
engine implementation. Unknown code, encrypted images, unsupported slices and
insufficient header padding are rejected. Each set pins its input SHA-256 and
byte preimages. The current reference is Telegram 13.1.1 (35634), whose patched
IPA and signature page hashes were checked. Swiftgram 12.3 has no Rust runtime
and continues to use MtProtoKit. Swiftgram with Rust and installation on an iOS
device remain to be tested.

The offline thunks use the registered Objective-C bridge when TGExtra is loaded
and call the original functions when it is absent. No executable memory is
rewritten at runtime. The generator currently supports thin generic arm64
images. The tweak itself still compiles for arm64 and arm64e.
Protected-forward recovery also runs when the original request uses Rust.
The refused forward is not resent. Source lookups, uploads and replacement
sends use the active Rust session; foreign-DC media downloads use the existing
MtProtoKit media workers with that session's account context. Both transports
share the same preflight, journals, acknowledgements, account isolation and
cancellation. Dependent requests wait until recovery finishes. The host receives
one completed request only after the copied sends are confirmed by the server.
Regenerate older Rust bridge archives: recovery needs the added context binding
and request-ID allocator metadata.

The protected-copy protocol and request lifecycle are covered by mocked network
tests; installation and compatibility with Telegram's actual pending-message
queue still require an iOS device. The same copy protocol is exercised through
both MtProtoKit and the Rust FFI adapter.

Edit history keeps versions of other people's messages observed while Anti-Edit
is enabled, including empty media captions. Your own messages are excluded;
previously saved revisions are removed when a message is identified as yours
from the network or displayed from cache. Displaying a cached incoming message also
records its stored text, available formatting entities and photo/document
identity, without scanning Telegram's database. Unrecognized fields stay unknown;
unknown accounts or message structures are skipped. Rich-message text,
formatting entities and attachment metadata are retained; the history labels
formatting and media changes even when the caption stays the same. It does not
archive attachment file bytes or provide playback of replaced attachments.
Each edited message retains its first observed version and up to 19 recent
revisions. Loading other messages does not evict saved histories; only the cache
of unedited originals is limited to 2000 messages. Versions the tweak never
received cannot be recovered.

Histories and deletion/timer markers are isolated by the local account record,
chat, message ID and message namespace. Ordinary, scheduled, quick-reply and
ephemeral messages cannot share a history accidentally. Sending a scheduled
message still removes it from the scheduled queue normally. Responses with an
older `editDate` cannot append a stale version; the latest date is persisted even when the text stays the same. Different edits bearing
the same second-resolution date are retained in network arrival order. A differing
cache snapshot with an equal or older edit date cannot overwrite the latest
version; an undated cache observation cannot roll back a recorded edit.
The pencil refreshes after the backing view's `layoutSubviews` and
`didMoveToWindow`, and on history notifications, without relying on
`ASDisplayNode.layout`. Repeated events share one main-queue pass, which reads
the current item after reuse. Its touch target stays within the message view,
and history opens from the button's own window.
Account identity comes from the connection's account directory and the message
node's account context. If it cannot be resolved, history recording and lookup
are skipped. The same rule applies to marker recording and lookup. Older
histories and markers without an account key remain stored under their original
preferences keys, but are not automatically assigned or displayed: their owning
account cannot be determined reliably.

Anti-Revoke handles individual cloud deletions and channel history-range
removals. TTL protection also runs on edits, service messages, dialog lists and
history/difference responses whose trailing User or Chat constructors are newer
than the bundled schema. Timer classifications and deletion markers are kept
until the message database is cleared; unrelated traffic cannot evict them.

To protect cloud messages during channel history revalidation, TGExtra retains
the last 2000 observed, unrevoked cloud messages in arrival order and pins
snapshots once their deletion is observed. For messages.getMessages and
channels.getMessages, a missing requested message can be supplied from the
matching account/chat snapshot. Ordinary observations are saved after a short
delay; deletion pins are saved immediately. This cannot restore an unobserved
or evicted message, a failed validation RPC, or media no longer available from
the server/cache.

This remains an injected tweak with Objective-C UI hooks and transport bridges. Secret
chat decryption, explicit local history clearing, local media expiry and other
Postbox operations performed without a network response are not intercepted.
Timers already stored before enabling protection are not retroactively removed.
There is no dependency on private Swift function hooks.

In the tweak menu, **Message Data → Clear Message Database** removes TGExtra's
edit histories, cached originals and snapshots, deletion/timer markers and
older history archives for all accounts after confirmation. Telegram chats and
tweak settings are preserved. Recording continues for subsequently received messages while the
corresponding features are enabled.

## GitHub releases

Pushes to `main` run checks and publish rootful/rootless/roothide packages plus
one cyan containing TGExtra and all committed client patch sets to `prerelease`.
Tags publish a versioned release. SideloadFix and NSEFix are no longer downloaded,
included or injected.

Set the repository Actions variable `DECRYPTED_IPA_URL` to enable automatic IPA
building after a successful tweak release. The downstream workflow uses the
triggering release's tag, checked-out revision and verified DEB digest. It applies
the Rust bridge before signing, publishes IPA/TIPA assets and merges the generated
client set into the universal release cyan. Other client sets are retained.

The IPA workflow can also be dispatched manually with `decrypted_ipa_url` and an
optional `release_tag`. Run it for additional clients to collect their sets in
the same cyan. Clients without Rust keep the ordinary MtProtoKit path. GitHub
must have the workflows enabled and the normal `GITHUB_TOKEN` release permission.

## Building and checks

Build with Theos and an iOS SDK using `make package`. The existing rootful,
rootless and roothide packaging schemes are retained.

After changing translations, run `python3 generate_langs.py` to regenerate the
embedded fallback translations.

To update the bundled API from a local Telegram-iOS checkout, run:

```sh
python3 Tools/update_telegram_api.py ~/Projects/Telegram-iOS
```

This requires Python 3.12+ and Swift. The script uses the last class-based
SwiftTL generator pinned in the script (Git may fetch missing objects), preserves
the tweak's codec patches and existing file layout, and records the source
revision and schema checksum in `Tools/TelegramApi/version.json`. The schema
snapshot is checked against all generated constructor/function IDs and fields
by `Tests/check_api_schema.py`.

Run `Tests/run.sh` on macOS to check protocol transformations, ghost exceptions,
settings migration, stored message reflection (including inherited optional
items and albums), cache/network history merging, account/namespace isolation,
formatting/media revisions, backing-view refresh coalescing and reuse, button
bindings and bounds, TTL paths, validation recovery and persisted history. Tests use in-memory
preferences.
The same suite checks protected-copy requests, chunked media transfers, account
isolation, cancellation, file-reference refresh, compact acknowledgements and
partial-send recovery through mock MtProtoKit and Rust FFI servers with
temporary journals. Rust tests also check dependent-request chains, 406 refusals,
missing account contexts, session destruction and liveness bookkeeping.
Telegram 13.1 wire fixtures check channel pins, full-user wallet/share-theme
fields, rich reply quotes and their preservation through TTL and copy rewrites.
The suite also checks the seven replaced 13.0 constructors and always-on iOS
content access, including channel lookups and bare user vectors, with every
optional feature disabled. Content-only rewrites preserve forwarding flags.
Apple-rule tests cover the client configuration, full-config requests, existing
server exceptions, compressed replies and live/history message text and media.
Rust bridge tests also cover account isolation, push/RPC transformations, cancellation,
buffer ownership and native execution of the generated arm64 call thunks.
UI interaction, video extraction and installation still require an iOS device.

For basic menu checks in Docker:

```sh
docker build -f Tests/Dockerfile -t tgextra-menu-tests .
docker run --rm -v "$PWD:/work:ro" tgextra-menu-tests
```

This checks resources and support-row detection, preprocesses all Logos hooks,
and compiles the Settings entry and message UI hooks for arm64/arm64e against iOS 16.5 with a 14.0
deployment target. It does not run UIKit or replace the macOS protocol tests.

Run `Tests/story_video_export.sh` on macOS with FFmpeg installed to check story
video frame rate, duration, audio, rotation and export failure handling.
Set `THEOS` or `LOGOS_PL` to also test the Photos hooks and temporary-file
cleanup. Pass a video path to additionally verify export of a real sample.

## Acknowledgements

The additional functions and menu are adapted from the local **mxgram / Mx**
fork, with its networking code adapted to TGExtra's bundled API and branding.


## Disclaimer

This project is an **independent modification (tweak)** for the Telegram app. I am **not affiliated, associated, authorized, endorsed by, or in any way officially connected with Telegram Messenger LLP**, or any of its subsidiaries or affiliates.

This tweak is created solely for **personal and educational purposes**. Use it at your own risk.

**I do not take any responsibility for any issues, damages, or consequences** resulting from the use or misuse of this tweak. If something breaks, it's not my problem.
