# TGExtra

A tweak for Telegram on iOS.

Open **Telegram Settings → TGExtra** at the bottom of the page. You can also
long-press **Ask a Question**, long-press the screen with three fingers, or tap
the Chats tab five times.

## Screenshots

![Screenshot 1](Screenshots/1.png)
![Screenshot 2](Screenshots/2.png)

## Features

- Disable ads and remove iOS content restrictions.
- Ghost Mode: hide online status, typing and other activity indicators, with
  separate switches for message, reaction, mention and story read receipts.
- Ghost exceptions: allow selected users to see typing and read receipts.
  Online status stays hidden globally.
- Save protected content and forward it as a new copy, preserving formatting,
  captions and albums. Supports photos, videos, documents, audio and voice messages.
- Ignore copy protection in private chats with a separate switch.
- Keep deleted messages and messages with chat auto-delete timers.
- Keep edit history; tap the pencil beside a message to view revisions.
- View disappearing media without starting its timer, with an optional label.
- Disable screenshot notifications for supported Telegram requests.
- Convert the audio track of a video to a voice message, using the preview trim.
- Save high-frame-rate videos and stories to Photos at 30 fps in H.264/AAC.
  Duration and audio are preserved; 24/30 fps videos are unchanged.
- Fix the Files picker and clear its temporary cache.
- Fake location and ten interface languages.
- Optional local Swiftgram Pro features through an iPatch v3 feature selected
  when building the IPA. Telegram Premium and server-provided services are separate.

New features default to off. Updates preserve existing preferences.

In iOSPatchingEngine, open the gear beside the uploaded TGExtra `.ipatch` and
enable **Swiftgram Pro** before building the IPA. It defaults to off and is not
part of the DEB or the in-app TGExtra menu. To disable it, rebuild from the
original IPA with the feature off. A new account needs an online launch to
initialize its status before the decoder patch can affect it.

**We strongly recommend supporting Swiftgram's author by purchasing Pro officially.**

The profile checks Swiftgram's `TelegramUIPreferences.SGStatus` metadata,
its single mutable `status: Int64` field, and reviewed fingerprints of both the
Decodable witness and its decoder body. It changes only successful decoded
values below 2; higher statuses and the original decoder's error handling are
preserved. It uses no injected Pro library or runtime witness-table mutation.
The reviewed arm64 reference is Swiftgram 13.1.1 (343, `app.swiftgram.ios`).
An enabled feature with an unsupported client fails the build; leaving it off
does not require a compatible Pro profile. The existing content,
screenshot-notification and advertising switches remain separate.
See [`Patches/`](Patches/README.md) for profile details and validation limits.

## Behavior and limitations

Restart Telegram after installing an update to refresh iOS content restrictions.
After changing the private-chat copy protection option, reopen the other person's
profile to refresh its cached settings.

Telegram acknowledges mentions, reactions and media playback together for each
message. Hiding one category can therefore suppress other content receipts for
that message. Other messages in the same request can still be acknowledged.
TGExtra keeps classifications for up to 4000 messages in memory. When content
privacy or disappearing-media protection is enabled, receipts that cannot be
classified safely are blocked until the message is received again. This also
applies when the account is unknown. Disappearing-media protection takes priority
over Ghost exceptions.

Protected forwarding downloads and uploads a new copy without the original
author header. It needs access to the source, permission to send in the destination
and temporary disk space. Polls, stickers, custom emoji media, paid or disappearing
media, rich-message bodies and some forward options are unsupported.

Edit history records other people's messages observed while the feature is
enabled, including formatting and attachment changes. Each edited message keeps
its first version and up to 19 recent revisions. Attachment files are not archived,
and versions TGExtra never received cannot be recovered. History is stored
separately for each Telegram account.

Deletion protection can restore previously observed messages during history
validation. It cannot recover messages missing from its cache or media missing
from both the server and local cache. Secret chats, explicit local history clearing and local
media expiry are not intercepted. Timers already stored before enabling protection
are not removed. Video conversion cannot undo slow motion rendered into a file.

**Message Data → Clear Message Database** clears TGExtra's histories, snapshots
and deletion/timer markers for all accounts. Telegram chats and tweak settings
are preserved. Protected-copy recovery journals are stored separately and are
not cleared by this action.

## Compatibility and Rust transport

TGExtra uses a bundled Swift codec from the
[Telegram 13.1 schema](https://github.com/TelegramMessenger/Telegram-iOS/commit/1dd3e7f4ed5d72caed1caa04033832c28a5920f5)
and also reads Telegram 13.0 message formats. UI hooks depend on the host app's
private interfaces.

Telegram 13.1's optional Rust MTProto transport requires a binary patch. Release
ipatch packages include the client patch sets in [`Patches/`](Patches/README.md).
iOSPatchingEngine v2 selects profiles by the original bundle ID and verified
machine-code structure, finds the runtime, links bridge payloads and generates
metadata for the selected image. It records input digests before applying edits.
Clients without Rust use MtProtoKit.

To generate a patch for another IPA and save its set for future releases:

```sh
python3 Tools/prepare_rust_patch.py Client.ipa TGExtra-Rust.ipatch --patch-set-dir Patches
```

The generator supports unencrypted, thin arm64 references matching its reviewed
C ABI 5 instruction patterns. It emits portable v2 profiles; add
`--engine /path/to/ipatch --plan-file plan.json` to validate through the engine.
The engine's fingerprint normalization must support references to zero-fill globals.
Unknown implementations and insufficient header padding are rejected. The
verified reference clients are Telegram 13.1.1 (35634) and Swiftgram 13.1.1 (343,
`app.swiftgram.ios`). Both profiles have passed engine planning and patch
application checks on their decrypted IPAs; on-device validation is still required.
Portable operations target generic arm64; the tweak builds for arm64 and arm64e.
Regenerate older bridge archives to include the metadata needed for protected-copy
recovery.

Both transports apply the same privacy and message policies. On Rust, suppressed
requests are replaced with `help.getNearestDc`, so they still need a network
connection. Protected-copy recovery uses the active session and records confirmed
sends to avoid repeating them on retry. Media downloads from other data centers
use MtProtoKit workers for the same account.

## Releases

Pushes to `main` run checks and publish rootful, rootless and roothide packages,
plus a matching `.ipatch` for each DEB, to `prerelease`. Each ipatch embeds its
corresponding DEB and all committed client patch sets. Tags publish versioned
releases. Install either the DEB or its ipatch; the ipatch requires a matching
Rust compatibility profile and a v3-capable engine. Swiftgram Pro is an optional
feature in those archives and is disabled by default.

The release workflow requires `GITHUB_TOKEN` release permissions.

## Building and checks

Build with Theos and an iOS SDK:

```sh
make package
```

After editing translations, regenerate the embedded fallbacks:

```sh
python3 generate_langs.py
```

To update the bundled API from a local Telegram-iOS checkout (Python 3.12+ and Swift):

```sh
python3 Tools/update_telegram_api.py ~/Projects/Telegram-iOS
```

The script preserves TGExtra's codec patches and records the source revision and
schema checksum in `Tools/TelegramApi/version.json`. Git may fetch missing objects.

Run the protocol and regression tests on macOS:

```sh
bash Tests/run.sh
```

The suite covers privacy, message protection, edit history, account isolation,
API compatibility and protected-copy recovery through mock MtProtoKit and Rust
servers. It uses in-memory preferences and temporary recovery journals.

To compile the menu and hooks for arm64/arm64e against iOS 16.5:

```sh
docker build -f Tests/Dockerfile -t tgextra-menu-tests .
docker run --rm -v "$PWD:/work:ro" tgextra-menu-tests
```

Run `bash Tests/story_video_export.sh` on macOS with FFmpeg to check video export.
Set `THEOS` or `LOGOS_PL` to also check the Photos hooks, or pass a video path to
test a sample. These checks do not replace installation and interaction tests
on an iOS device.

## Acknowledgements

Additional functions and the menu are adapted from the **mxgram / Mx** fork.

## Disclaimer

TGExtra is an independent project, unaffiliated with Telegram. It is provided for
personal and educational use, at your own risk. The author accepts no responsibility
for damage caused by its use.
