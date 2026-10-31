# TGExtra

A tweak for Telegram on iOS.

Developed by **KDevLab**. Original idea by **Chocolatefluffy**.

Open **Telegram Settings → TGExtra** below **My Profile**. In Swiftgram, TGExtra
appears after Swiftgram's own settings rows.

## Screenshots

![Screenshot 1](Screenshots/1.png)
![Screenshot 2](Screenshots/2.png)

## Features

- Disable ads and remove iOS content restrictions.
- Ghost Mode: hide online status, typing and activity indicators. Control message,
  reaction, mention and story read receipts separately.
- Allow selected users to see typing and read receipts. Online status stays hidden
  for everyone.
- Save protected content and forward photos, videos, documents, audio and voice
  messages as new copies, preserving formatting, captions and albums.
- Save purchased and secret-chat photos and videos from the gallery.
- Ignore copy protection in private chats.
- Keep deleted messages and messages with auto-delete timers.
- Keep edit history; tap the pencil beside a message to view revisions.
- View disappearing media without starting its timer.
- Allow screenshots in secret-chat galleries and disable screenshot notifications.
- Send a video's trimmed audio as a voice message from the video preview.
- Send a video as a round message using the adjacent preview button: centered
  square crop, up to 60 seconds of the selected trim. Enable **Video to Round
  Message** in TGExtra's media settings to show the button.
- Save high-frame-rate videos and stories to Photos at 30 fps in H.264/AAC.
  Videos at 24/30 fps are unchanged.
- Fix the Files picker and clear its temporary cache.
- Set a fake location. Choose from ten interface languages.
- Disable double-tap reactions while keeping reaction buttons and the long-press
  menu.
- Hide the voice/round-video recording button in Telegram and Swiftgram under
  **Interface and gestures**. Apply changes and relaunch.
- Use tlottie instead of rlottie on clients with a compatible renderer. Restart
  after changing the option.
- Enable local Swiftgram Pro features when building an IPA; see below.

New features default to off. Updates preserve existing preferences.

## Installation and compatibility

Releases include rootful, rootless and roothide DEBs, with a matching `.ipatch`
for each package. Install the DEB or use the `.ipatch` with iOSPatchingEngine v4.
Clients using Rust MTProto need a matching compatibility profile.

Reference builds: Telegram 13.1.2 (35638) and Swiftgram 13.1.1
(343/344, `app.swiftgram.ios`). Newer builds may need updated profiles or UI hooks.
Protocol privacy and message protection require the app's TLS1 v3 schema.
Device testing is still needed.

Secret-chat notification, deletion and timer protection require rebuilding the
IPA with the `.ipatch`; a DEB alone is insufficient. These profiles support
generic arm64.

**Message Data → Debug Log** shows schema and hook status. Swiftgram's optional
copy-protection UI hook may be skipped because its flag has no Objective-C
getter; protocol copy protection still works. See [Patches/README.md](Patches/README.md)
for profile details.

Restart Telegram after installing an update to refresh iOS content restrictions.
After changing the private-chat copy protection option, reopen the other person's
profile to refresh its cached settings.

### Swiftgram Pro

In iOSPatchingEngine, open the gear beside the uploaded TGExtra `.ipatch` and
select **Swiftgram Pro** before building the IPA. It is disabled by default and
is not available through the DEB or the in-app menu. To disable it, rebuild from
the original IPA with the feature off.

This enables local Swiftgram Pro features, not Telegram Premium or server-provided
services. A new account needs an online launch to initialize its status. Enabling
this feature on an unsupported client fails the build.

Please support Swiftgram's author by purchasing Pro officially.

## Limitations

### Privacy

Telegram acknowledges mentions, reactions and media playback together for each
message. Hiding one category can suppress the other receipts for that message.
When content privacy or disappearing-media protection is enabled, unclassified
receipts are blocked until the message is received again. This also applies when
the account is unknown. Disappearing-media protection takes priority over Ghost
exceptions.

Both MtProtoKit and Rust use the same privacy and message policies. On Rust,
suppressed requests are replaced with `help.getNearestDc` and still require a
network connection.

### Saving and forwarding

Protected forwarding downloads and uploads a new copy without the original author
header. It requires access to the source, permission to send in the destination
and temporary disk space. Polls, stickers, custom emoji media, paid or disappearing
media, rich-message bodies and some forward options are unsupported.

To save purchased or secret-chat media, enable **Save Protected Content** and tap
the gallery's top-right download button. Purchased media must be unlocked. If its
file reference has expired, reopen the purchase and retry. Errors appear in
**Message Data → Debug Log**.

The same setting allows screenshots of purchased media.

Keep the gallery open until the file finishes downloading. Secret media is saved
from Telegram's decrypted cache. Enable **View Disappearing Media Freely** before
opening timed media to prevent its countdown from starting.

Video conversion cannot undo slow motion rendered into a file.

### Message history

Edit history records other people's messages received while the feature is
enabled, including formatting and attachment changes. Each message keeps its
first version and up to 19 recent revisions, stored separately for each account.
Removed words appear red and struck through; added words appear green and
underlined. Attachment files and versions TGExtra never received are not saved.

Deletion protection can restore messages TGExtra previously observed. It cannot
recover uncached messages or media missing from both the server and local cache.

In secret chats, **Save Deleted Messages** blocks the other participant's deletion
and history-clearing commands. Individually deleted messages show the deletion
icon; updating this behavior requires rebuilding the IPA with the updated `.ipatch`.
**View Disappearing Media Freely** and
**Save Auto-Delete Messages** prevent local expiry. You can still clear history
yourself. Protection only affects your device.

Existing secret-chat countdowns are kept, but their expiry is skipped while
protection is enabled. Existing cloud auto-delete timers are not removed.

Histories, recovery snapshots and deletion/timer markers are stored incrementally
in SQLite. Existing data is migrated automatically when updating.

**Message Data → Clear Message Database** clears TGExtra's histories, snapshots
and deletion/timer markers for all accounts. Messages retained after deletion
are also removed from Telegram's local history, updating the chat automatically.
Inactive accounts finish this removal when opened; only pending deletion IDs
are kept until their local transaction completes. Other messages and tweak settings
are preserved. Protected-copy recovery journals are stored separately and are
not cleared by this action.

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
use. To use an existing installation, set `THEOS=/path/to/theos`. Packages are
written to `packages/arm64/`; all three dylibs contain only arm64 code.

After editing translations, regenerate the embedded fallbacks:

```sh
python3 generate_langs.py
```

To update the typed policy views and test fixture from an original decrypted IPA:

```sh
python3 Tools/update_telegram_api.py packages/Telegram_v13.1.2.ipa
```

The schema is stored under `Tests/Fixtures` with its checksum and app version.
Production reads the installed app's table. After adding a view usage in Swift,
regenerate from the existing fixture without supplying an IPA:

```sh
python3 Tools/update_telegram_api.py
```

Message policies live in
[MessagePatches.swift](Sources/tgapi/TL/MessagePatches.swift), revision storage in
[MessageHistory.swift](Sources/tgapi/MessageHistory.swift), and patch generation
and packaging are documented in [Patches/README.md](Patches/README.md).

## Checks

Run the protocol and regression tests on macOS:

```sh
bash Tests/run.sh
```

Tests build for the Mac's native architecture on both Intel and Apple Silicon;
Rosetta is not required. CI runs the suite on Intel. UIKit checks require the
Mac Catalyst SDK; compiling Logos hooks also requires the Logos preprocessor.
Tests executing arm64 machine code require Apple Silicon.
Optional downloader diagnostics are separate from the normal run:

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

Run `bash Tests/story_video_export.sh` on macOS with FFmpeg to check video export.
Run `bash Tests/round_video_export.sh` to check round-video cropping, trimming,
orientation, codecs and the duration limit.
Set `THEOS` or `LOGOS_PL` to also check the Photos hooks, or pass a video path to
test a sample. These checks do not replace testing on an iOS device.

## Releases

Pushes to `main` run checks and publish packages to `prerelease`. Tags publish
versioned releases. Each `.ipatch` includes its matching DEB and the client patch
profiles built and tested by CI. The workflow requires `GITHUB_TOKEN` release
permissions.

## Acknowledgements

Additional functions and the menu are adapted from the **mxgram / Mx** fork.

## Disclaimer

TGExtra is an independent project, unaffiliated with Telegram. It is for personal
and educational use, at your own risk. The author accepts no responsibility for
damage caused by its use.
