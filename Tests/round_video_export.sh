#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
command -v ffmpeg >/dev/null
test_build_dir=$(mktemp -d /private/tmp/tgextra-round-tests.XXXXXX)
trap 'rm -rf "$test_build_dir"' EXIT
ffmpeg -v error -f lavfi -i 'color=c=yellow:size=128x64:rate=30' \
    -f lavfi -i 'sine=frequency=440:sample_rate=44100' -t 3 \
    -vf "drawbox=x=0:y=0:w=32:h=64:color=red:t=fill,drawbox=x=96:y=0:w=32:h=64:color=blue:t=fill,drawbox=x=32:y=0:w=64:h=64:color=lime:t=fill:enable='gte(t,1)'" \
    -c:v libx264 -pix_fmt yuv420p -c:a aac "$test_build_dir/source.mp4"
ffmpeg -v error -i "$test_build_dir/source.mp4" -c:v copy -an "$test_build_dir/silent.mp4"
clang -fobjc-arc -Werror -Wno-deprecated-declarations \
    -framework Foundation -framework AVFoundation -framework CoreMedia \
    -framework CoreGraphics Sources/tgapi/Logger/Logger.m Sources/tgapi/RoundVideoExport.m Tests/round_video_export.m \
    -o "$test_build_dir/RoundVideoExportTests"
"$test_build_dir/RoundVideoExportTests" "$test_build_dir"
