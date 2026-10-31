# TGExtra

A tweak for Telegram on iOS.

Developed by **KDevLab**. Original idea by **Chocolatefluffy**.

Open **Telegram Settings → TGExtra**, below **My Profile** or Swiftgram's settings.

## Screenshots

![Screenshot 1](Screenshots/1.png)
![Screenshot 2](Screenshots/2.png)

## Features

- Disable ads and remove iOS content restrictions.
- Ghost Mode: hide online status, typing and activity indicators. Control message,
  reaction, mention and story read receipts separately.
- Add Ghost Mode exceptions for typing and read receipts. Online status stays
  hidden for everyone.
- Save protected content and forward photos, videos, documents, audio and voice
  messages as new copies, preserving formatting, captions and albums.
- Save purchased and secret-chat photos and videos from the gallery.
- Ignore copy protection in private chats.
- Keep deleted messages and messages with auto-delete timers.
- Keep edit history; tap the pencil beside a message to view revisions.
- View disappearing media without starting its timer.
- Allow screenshots in secret-chat galleries and disable screenshot notifications.
- Send a video's trimmed audio as a voice message from the video preview.
- Send a video as a round message: centered square crop, up to 60 seconds of the
  selected trim. Enable **Video to Round Message** in media settings to show the
  preview button. Unavailable in secret chats.
- Save high-frame-rate videos and stories to Photos at 30 fps in H.264/AAC.
  Videos at 24/30 fps are unchanged.
- Fix the Files picker and clear its temporary cache.
- Automatically remove temporary upload sources after Telegram copies them to its media cache.
- Set a fake location.
- Choose from ten interface languages.
- Disable double-tap reactions.
- Hide the voice/round-video recording button under **Interface and gestures**.
  Requires a relaunch.
- Use tlottie instead of rlottie on clients with a compatible renderer. Restart
  after changing the option.
- Enable local Swiftgram Pro features when building an IPA.

New features default to off. Updates preserve existing preferences.

## Installation and compatibility

Releases include rootful, rootless and roothide DEBs and matching `.ipatch` files.
Install the DEB or build an IPA with iOSPatchingEngine v4. Rust MTProto clients
need a matching compatibility profile.

Reference builds: Telegram 13.1.2 (35638) and Swiftgram 13.1.1
(343/344, `app.swiftgram.ios`). Newer builds may need updated profiles or UI hooks.
Privacy and message protection require the app's TLS1 v3 schema.

Secret-chat notification, deletion and timer protection require an IPA built
with the `.ipatch`. The profiles target arm64.

**Message Data → Debug Log** shows schema and hook status. Swiftgram may report
its copy-protection UI hook as unavailable while protocol protection still works.
Profile details: [Patches/README.md](Patches/README.md).

Restart Telegram after installing an update to refresh iOS content restrictions.
After changing the private-chat copy protection option, reopen the other person's
profile to refresh its cached settings.

### Swiftgram Pro

In iOSPatchingEngine, open the gear beside the TGExtra `.ipatch` and select
**Swiftgram Pro** before building the IPA. This option is off by default and
available only when building an IPA. To disable it, rebuild from the original
IPA with the option off.

This enables local Swiftgram Pro features. Telegram Premium and server-provided
services are not included. New accounts need one online launch to initialize
their status. The build fails if the client is unsupported.

Support Swiftgram's author by purchasing Pro officially.

## Limitations

### Privacy

Telegram acknowledges mentions, reactions and media playback together for each
message. Hiding one category can suppress the other receipts for that message.
With content privacy or disappearing-media protection enabled, TGExtra blocks
receipts if it cannot identify the message or account. Message classification
updates when the message is received again. Disappearing-media protection takes
priority over Ghost Mode exceptions.

On Rust MTProto, hiding activity still requires a network connection: TGExtra
replaces suppressed requests with `help.getNearestDc`.

### Saving and forwarding

Protected forwarding downloads and uploads a copy without the original author
header. You need access to the source, permission to send in the destination and
temporary disk space. Polls, stickers, custom emoji media, paid or disappearing
media, rich-message bodies and some forwarding options are unsupported.

To save purchased or secret-chat media, enable **Save Protected Content** and tap
the gallery's top-right download button. Keep the gallery open until the download
finishes. Purchased media must be unlocked; if its file reference has expired,
reopen the purchase and retry. Errors appear in **Message Data → Debug Log**.
The setting also allows screenshots of purchased media.

Secret media is saved from Telegram's decrypted cache. Enable **View Disappearing
Media Freely** before opening timed media to prevent its countdown from starting.

Video conversion cannot undo slow motion rendered into a file.

### Message history

Edit history records other people's messages received while the feature is
enabled, including formatting and attachment changes. Each message keeps its
first version and up to 19 recent revisions, stored separately for each account.
Removed words appear red and struck through; added words appear green and
underlined. Attachment files and versions TGExtra never received are not saved.

Deletion protection can restore messages TGExtra previously received. Recovery
requires a saved message snapshot; attachments must remain on the server or in
Telegram's local cache.

In secret chats, **Save Deleted Messages** blocks the other participant's deletion
and history-clearing commands. Individually deleted messages show the deletion
icon. **View Disappearing Media Freely** and **Save Auto-Delete Messages** prevent
local expiry. You can still clear history yourself. Protection only affects
your device.

Existing secret-chat countdowns continue, but expired messages stay while
protection is enabled. After disabling protection, expired messages are deleted
within 30 seconds for active accounts, or when an inactive account is opened.
Existing cloud auto-delete timers are not removed.

History is stored locally in SQLite and survives updates.

**Message Data → Force Clear Temporary Files** removes TGExtra's picker files,
converted voice messages and video notes, temporary media exports, and legacy
TGExtra logs in Documents and the app's shared containers. The
confirmation shows their file count and total size. Wait for
sends, conversions and saves to finish first; forcing cleanup can interrupt them.
Saved message history, settings and forward-recovery journals are kept.
Interrupted media exports are also cleaned up at the next app launch. Clearing
the message database compacts its SQLite file to release disk space.

**Message Data → Clear Message Database** clears TGExtra's histories, snapshots
and deletion/timer markers for all accounts. Messages retained after deletion
are also removed from Telegram's local history. Inactive accounts are cleaned
when opened. Other messages, tweak settings and protected-forward recovery data
are kept.

## Building

Build with Theos and an iOS SDK:

```sh
make package
```

To run the GitHub Actions checks and build arm64 DEBs and matching iPatches for
all three jailbreak schemes on macOS with Xcode:

```sh
brew install make ldid
./build-arm64.sh
```

The script downloads `waruhachi/theos` and `waruhachi/sdks` from `main` on first
use. Set `THEOS=/path/to/theos` to use an existing installation. Packages are
written to `packages/arm64/` and contain arm64 code only.

To remove compiler caches, Theos intermediates and generated patch binaries:

```sh
bash Tools/clean.sh
```

This preserves SDKs and Theos in `.build/`, research drafts, and everything in
`packages/`, including original IPAs. Patch binaries are rebuilt by
`Tools/build_payloads.py` or `Tests/run.sh`. Run cleanup after builds and tests
have finished.

After editing translations, regenerate the embedded fallbacks:

```sh
python3 generate_langs.py
```

To update the typed policy views and test fixture from an original decrypted IPA:

```sh
python3 Tools/update_telegram_api.py packages/Telegram_v13.1.2.ipa
```

The fixture schema is stored in `Tests/Fixtures`; the tweak reads the installed
app's schema at runtime. After using additional API types in Swift, regenerate
the views from the existing fixture:

```sh
python3 Tools/update_telegram_api.py
```

The generator scans `Sources`. Tests generate their own views with `--test-output`.

Message policies: [MessagePatches.swift](Sources/tgapi/TL/MessagePatches.swift).
Revision storage: [MessageHistory.swift](Sources/tgapi/MessageHistory.swift).
Patch generation and packaging: [Patches/README.md](Patches/README.md).

## Checks

Run the protocol and regression tests on macOS:

```sh
bash Tests/run.sh
```

Tests run natively on Intel and Apple Silicon; CI uses Intel. UIKit checks require
the Mac Catalyst SDK, and Logos hooks require the Logos preprocessor. Tests that
execute arm64 machine code require Apple Silicon.

Downloader diagnostics:

```sh
python3 Tests/paid_media_download.py --sanitize
```

To run benchmarks:

```sh
bash Tests/run.sh --benchmark
bash Tests/run.sh --native-benchmark
```

To compile the menu and hooks for arm64/arm64e against iOS 16.5:

```sh
docker build -f Tests/Dockerfile -t tgextra-menu-tests .
docker run --rm -v "$PWD:/work:ro" tgextra-menu-tests
```

Video export checks require macOS and FFmpeg:

```sh
bash Tests/story_video_export.sh
bash Tests/round_video_export.sh
```

Set `THEOS` or `LOGOS_PL` to include Photos hook checks, or pass a video path to
test your own sample.

## Releases

Pushes to `main` publish packages to `prerelease` after checks pass. Tags publish
versioned releases. Each `.ipatch` contains a matching DEB and client profiles.
The workflow requires `GITHUB_TOKEN` release permissions.

## Acknowledgements

Some features and the menu are adapted from the **mxgram / Mx** fork.

## Disclaimer

TGExtra is unaffiliated with Telegram and intended for personal and educational
use. Use at your own risk; the author accepts no responsibility for damage.
