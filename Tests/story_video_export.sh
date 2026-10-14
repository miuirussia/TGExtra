#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
command -v ffmpeg >/dev/null
test_build_dir=$(mktemp -d /private/tmp/tgextra-story-tests.XXXXXX)
trap 'rm -rf "$test_build_dir"' EXIT
ffmpeg -v error -f lavfi -i 'testsrc2=size=96x64:rate=120' \
    -f lavfi -i 'sine=frequency=440:sample_rate=44100' -t 2 \
    -c:v libx264 -pix_fmt yuv420p -c:a aac -metadata comment=source \
    "$test_build_dir/high-fps.mp4"
ffmpeg -v error -f lavfi -i 'testsrc2=size=96x64:rate=24' -t 1 \
    -c:v libx264 -pix_fmt yuv420p "$test_build_dir/silent.mp4"
clang -fobjc-arc -Werror -Wno-deprecated-declarations \
    -framework Foundation -framework AVFoundation -framework CoreMedia \
    -framework CoreVideo -framework CoreGraphics \
    Sources/tgapi/StoryVideoExport.m Tests/story_video_export.m \
    -o "$test_build_dir/StoryVideoExportTests"
"$test_build_dir/StoryVideoExportTests" "$test_build_dir"
