#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

python3 Tests/check_resources.py
python3 Tests/settings_support_labels.py

: "${LOGOS_PL:?Set LOGOS_PL to the Logos preprocessor}"
: "${IOS_SDK:?Set IOS_SDK to an iOS SDK directory}"
test_build_dir=$(mktemp -d)
trap 'rm -rf "$test_build_dir"' EXIT

# Parse every Logos source, including the shared UI helpers.
while IFS= read -r source; do
    perl "$LOGOS_PL" -c generator=internal "$source" > "$test_build_dir/$(basename "$source").mm"
done < <(find Sources -name '*.xm' -print)

# Compile the real new hook against UIKit, rather than a UIKit test double.
# Linux can generate Mach-O objects, but cannot link/run an iOS application.
for arch in arm64 arm64e; do
    clang++ -target "$arch-apple-ios14.0" -isysroot "$IOS_SDK" \
        -fobjc-arc -Werror -Wno-deprecated-declarations -c \
        "$test_build_dir/SettingsMenu.xm.mm" -o "$test_build_dir/SettingsMenu-$arch.o"
done
echo 'PASS Logos preprocessing and iOS Settings menu hook compilation (arm64, arm64e)'
