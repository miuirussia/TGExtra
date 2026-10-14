# TGExtra
A simple Telegram iOS Tweak.

Open the tweak menu by long-pressing **Ask a Question** in Telegram Settings,
long-pressing the screen with three fingers, or tapping the Chats tab five times.

## Screenshots

![Screenshot 1](Screenshots/1.png)
![Screenshot 2](Screenshots/2.png)

## Features

- Disable Ads
- Ghost Mode
- No Read Receipt for messages and Stories
- Ghost exceptions: manage users from their profile or the tweak menu. Exceptions
  apply to typing and read receipts; online status remains hidden globally.
- Save and forward protected content
- Normalize high-frame-rate videos (including 120 fps stories) to H.264/AAC at
  30 fps before saving to Photos when the protected-content bypass is enabled,
  preserving duration and audio. Ordinary 24/30/60 fps videos are unchanged.
  This does not undo slow motion already rendered into a previously saved file.
- Ignore copy protection in private chats, independently of the protected-content
  toggle. Reopen the other person's profile after changing this option to refresh
  cached chat settings. The server-side sharing setting remains unchanged.
- Keep deleted messages and messages with chat auto-delete timers
- Keep original text and edit history; tap the pencil beside a message to view revisions
- Disable screenshot notifications for supported Telegram requests
- View disappearing media without starting its timer, with an optional label
- Video to Voice: send the audio track as a voice message, respecting preview trims
- Fix the Files picker and clear its temporary cache
- Fake location and ten interface languages

The integration uses the Telegram API 13.0 sources already in this repository.
Private UI hooks depend on the host app exposing the corresponding methods.
New features default to off; existing preferences are preserved on upgrade.

## Building and checks

Build with Theos and an iOS SDK using `make package`. The existing rootful,
rootless and roothide packaging schemes are retained.

After changing translations, run `python3 generate_langs.py` to regenerate the
embedded fallback translations.

Run `Tests/run.sh` on macOS to check protocol transformations, ghost exceptions,
settings migration and persisted history. Tests use in-memory preferences.
UI interaction, video extraction and installation still require an iOS device.
Run `Tests/story_video_export.sh` on macOS with FFmpeg installed to check story
video frame rate, duration, audio, rotation and export failure handling.
Set `THEOS` or `LOGOS_PL` to also test the Photos hooks and temporary-file
cleanup. Pass a video path to additionally verify export of a real sample.

## Acknowledgements

The additional functions and menu are adapted from the local **mxgram / Mx**
fork, with its networking code adapted to TGExtra's API 13.0 and branding.


## Disclaimer

This project is an **independent modification (tweak)** for the Telegram app. I am **not affiliated, associated, authorized, endorsed by, or in any way officially connected with Telegram Messenger LLP**, or any of its subsidiaries or affiliates.

This tweak is created solely for **personal and educational purposes**. Use it at your own risk.

**I do not take any responsibility for any issues, damages, or consequences** resulting from the use or misuse of this tweak. If something breaks, it's not my problem.
