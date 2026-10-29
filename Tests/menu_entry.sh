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
    clang -target "$arch-apple-ios14.0" -isysroot "$IOS_SDK" \
        -fobjc-arc -Werror -Wno-deprecated-declarations \
        -I "$test_build_dir" -I Sources/tgapiC/include -c \
        Sources/tgapi/UI/TGExtra.m -o "$test_build_dir/TGExtra-$arch.o"
    clang -target "$arch-apple-ios14.0" -isysroot "$IOS_SDK" \
        -fobjc-arc -Werror -Wno-deprecated-declarations \
        -I "$test_build_dir" -I Sources/tgapiC/include -c \
        Sources/tgapi/UI/SettingsNavigation.m -o "$test_build_dir/SettingsNavigation-$arch.o"
    clang -target "$arch-apple-ios14.0" -isysroot "$IOS_SDK" \
        -fobjc-arc -Werror -Wno-deprecated-declarations -c \
        Sources/tgapi/Preferences.m -o "$test_build_dir/Preferences-$arch.o"
    clang -target "$arch-apple-ios14.0" -isysroot "$IOS_SDK" \
        -fobjc-arc -Werror -c Sources/tgapi/ForceTLottie.m -o "$test_build_dir/ForceTLottie-$arch.o"
    for source in SettingsRows LanguageSelector LocationSelector TGExtraLocalization EditHistoryDiff EditHistoryViewController; do
        clang -target "$arch-apple-ios14.0" -isysroot "$IOS_SDK" \
            -fobjc-arc -Werror -Wno-deprecated-declarations -I "$test_build_dir" \
            -c "Sources/tgapi/UI/$source.m" -o "$test_build_dir/$source-$arch.o"
    done
    for source in FilePickerFix LocationHook; do
        clang++ -target "$arch-apple-ios14.0" -isysroot "$IOS_SDK" \
            -fobjc-arc -Werror -Wno-deprecated-declarations -I "$test_build_dir" \
            -I Sources/tgapi -I Sources/tgapiC/include \
            -c "$test_build_dir/$source.xm.mm" -o "$test_build_dir/$source-$arch.o"
    done
    for source in PaidMediaDownload PaidMediaImport PaidMediaSave; do
        clang -target "$arch-apple-ios14.0" -isysroot "$IOS_SDK" \
            -fobjc-arc -Werror -Wno-deprecated-declarations -I Sources/tgapiC/include -I "$test_build_dir" \
            -c "Sources/tgapi/$source.m" -o "$test_build_dir/$source-$arch.o"
    done
    clang++ -target "$arch-apple-ios14.0" -isysroot "$IOS_SDK" \
        -fobjc-arc -Werror -Wno-deprecated-declarations -std=c++11 \
        -I "$test_build_dir" -I Sources/tgapi -I Sources/tgapiC/include -c \
        "$test_build_dir/VideoToVoice.xm.mm" -o "$test_build_dir/VideoToVoice-$arch.o"
    clang++ -target "$arch-apple-ios14.0" -isysroot "$IOS_SDK" \
        -fobjc-arc -Werror -Wno-deprecated-declarations \
        -I Sources/tgapi -I Sources/tgapiC/include -c \
        "$test_build_dir/PaidMediaCapture.xm.mm" -o "$test_build_dir/PaidMediaCapture-$arch.o"
    clang++ -target "$arch-apple-ios14.0" -isysroot "$IOS_SDK" \
        -fobjc-arc -Werror -Wno-deprecated-declarations \
        -I Sources/tgapi -I Sources/tgapiC/include -c \
        "$test_build_dir/Hooks.xm.mm" -o "$test_build_dir/Hooks-$arch.o"
    clang -target "$arch-apple-ios14.0" -isysroot "$IOS_SDK" \
        -fobjc-arc -Werror -Wno-deprecated-declarations \
        -I Sources/tgapiC/include -c Sources/tgapi/RustBridge.m -o "$test_build_dir/RustBridge-$arch.o"
    clang -target "$arch-apple-ios14.0" -isysroot "$IOS_SDK" \
        -fobjc-arc -Werror -Wno-deprecated-declarations \
        -I Sources/tgapiC/include -c Sources/tgapiC/NativeTL.m -o "$test_build_dir/NativeTL-$arch.o"
    clang -target "$arch-apple-ios14.0" -isysroot "$IOS_SDK" \
        -fobjc-arc -Werror -Wno-deprecated-declarations \
        -I Sources/tgapiC/include -c Sources/tgapi/ForwardCopy.m -o "$test_build_dir/ForwardCopy-$arch.o"
    clang++ -target "$arch-apple-ios14.0" -isysroot "$IOS_SDK" \
        -fobjc-arc -Werror -Wno-deprecated-declarations -I Sources/tgapi/UI -c \
        "$test_build_dir/SettingsMenu.xm.mm" -o "$test_build_dir/SettingsMenu-$arch.o"
    clang++ -target "$arch-apple-ios14.0" -isysroot "$IOS_SDK" \
        -fobjc-arc -Werror -Wno-deprecated-declarations -I Sources/tgapi -c \
        "$test_build_dir/DoubleTapReactions.xm.mm" -o "$test_build_dir/DoubleTapReactions-$arch.o"
    clang++ -target "$arch-apple-ios14.0" -isysroot "$IOS_SDK" \
        -fobjc-arc -Werror -Wno-deprecated-declarations \
        -I "$test_build_dir" -I Sources/tgapi/UI -I Sources/tgapiC/include -c \
        "$test_build_dir/UIHooks.xm.mm" -o "$test_build_dir/UIHooks-$arch.o"
done
echo 'PASS Logos preprocessing and Settings/message UI/network hook compilation (arm64, arm64e)'
