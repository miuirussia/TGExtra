#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
test_build_dir=$(mktemp -d /private/tmp/tgextra-round-recovery.XXXXXX)
trap 'rm -rf "$test_build_dir"' EXIT
clang -fobjc-arc -Werror -Wno-deprecated-declarations -DTGEXTRA_TESTING \
    -framework Foundation -framework AVFoundation -framework CoreMedia -framework CoreGraphics \
    Sources/tgapi/Logger/Logger.m Tests/round_video_recovery.m -o "$test_build_dir/tests"
"$test_build_dir/tests"
