#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

python3 Tests/check_resources.py
python3 Tests/check_api_schema.py
python3 Tests/settings_support_labels.py
python3 Tests/settings_navigation.py

: "${LOGOS_PL:?Set LOGOS_PL to the Logos preprocessor}"
: "${IOS_SDK:?Set IOS_SDK to an iOS SDK directory}"
test_build_dir=$(mktemp -d)
trap 'rm -rf "$test_build_dir"' EXIT

# Parse every Logos source, including the shared UI helpers.
while IFS= read -r source; do
    perl "$LOGOS_PL" -c generator=internal "$source" > "$test_build_dir/$(basename "$source").mm"
done < <(find Sources -name '*.xm' -print)

# Compile the actual hooks against UIKit. UIHooks includes roothide.h through
# its shared header but uses none of its definitions; packaging provides the
# real header. Linux can generate Mach-O objects but cannot run UIKit.
printf '%s\n' '#define jbroot(path) (path)' > "$test_build_dir/roothide.h"
for arch in arm64 arm64e; do
    flags=(-target "$arch-apple-ios14.0" -isysroot "$IOS_SDK" -fobjc-arc -Werror
        -Wno-deprecated-declarations -I "$test_build_dir" -I Sources/tgapiC/include
        -I Sources/tgapi -I Sources/tgapi/UI)
    while IFS= read -r source; do
        clang "${flags[@]}" -c "$source" -o "$test_build_dir/$(basename "$source")-$arch.o"
    done < <(find Sources -name '*.m' -print | sort)
    while IFS= read -r source; do
        clang++ "${flags[@]}" -iquote "$(dirname "$source")" -std=c++11 -c "$test_build_dir/$(basename "$source").mm" \
            -o "$test_build_dir/$(basename "$source")-$arch.o"
    done < <(find Sources -name '*.xm' -print | sort)
done
echo 'PASS all Objective-C sources and Logos hooks compile for arm64 and arm64e'
