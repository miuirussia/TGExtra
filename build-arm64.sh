#!/bin/bash
# Local counterpart of .github/workflows/build.yml, limited to arm64.
set -euo pipefail
cd "$(dirname "$0")"

if [[ "$(uname -s)" != Darwin ]]; then
    echo "This build requires macOS and Xcode." >&2
    exit 1
fi

# Use Xcode even when xcode-select points at Command Line Tools.
if [[ -z "${DEVELOPER_DIR:-}" ]] && ! xcrun --sdk iphoneos --show-sdk-path >/dev/null 2>&1; then
    export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi
xcrun --sdk iphoneos --show-sdk-path >/dev/null

make_command=make
if command -v gmake >/dev/null 2>&1; then
    make_command=gmake
fi
if ! "$make_command" --version | head -n 1 | grep -Eq 'GNU Make ([4-9]|[1-9][0-9]+)\.' || ! command -v ldid >/dev/null 2>&1; then
    echo "Install the build dependencies first: brew install make ldid" >&2
    exit 1
fi

export THEOS="${THEOS:-$PWD/.build/theos}"
if [[ ! -d "$THEOS" ]]; then
    git clone --branch main --recurse-submodules https://github.com/waruhachi/theos.git "$THEOS"
fi
if [[ ! -d "$THEOS/sdks/iPhoneOS16.5.sdk" ]]; then
    # Theos includes a placeholder sdks directory; clone alongside it.
    if [[ ! -d "$PWD/.build/sdks" ]]; then
        git clone --branch main --recurse-submodules https://github.com/waruhachi/sdks.git "$PWD/.build/sdks"
    fi
    mkdir -p "$THEOS/sdks"
    ln -s "$PWD/.build/sdks/iPhoneOS16.5.sdk" "$THEOS/sdks/iPhoneOS16.5.sdk"
fi

export CLANG_MODULE_CACHE_PATH="$PWD/.build/module-cache"
export SWIFT_MODULECACHE_PATH="$PWD/.build/swift-module-cache"
output="$PWD/packages/arm64"
mkdir -p "$output"

# The same checks and payload compilation as the workflow's checks job.
python3 Tools/build_payloads.py
bash Tests/run.sh

for scheme in rootful rootless roothide; do
    scheme_arg=""
    if [[ "$scheme" != rootful ]]; then
        scheme_arg="$scheme"
    fi
    echo ">>> Building $scheme (arm64)..."
    "$make_command" clean package FINALPACKAGE=1 ARCHS=arm64 \
        "THEOS_PACKAGE_SCHEME=$scheme_arg" "THEOS_PACKAGE_DIR=$output"
done

for deb in "$output"/*.deb; do
    python3 Tools/package_ipatch.py --deb "$deb" --patches Patches \
        --output "${deb%.deb}.ipatch"
done

echo ">>> DEB and iPatch packages: $output"
