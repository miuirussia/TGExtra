#!/bin/bash
# Remove generated files while keeping dependencies, packages and research drafts.
set -euo pipefail
cd "$(dirname "$0")/.."

rm -rf .theos .build/module-cache .build/swift-module-cache \
    .build/clang-module-cache .build/ccache
find Tools Tests -type d -name __pycache__ -prune -exec rm -rf {} +
find Patches -type f -path '*/payloads/*.bin' -delete
find . -type d \( -name .git -o -name .build \) -prune -o \
    -type f -name .DS_Store -exec rm -f {} +

echo 'Removed compiler caches, Theos outputs, compiled payloads and Python caches.'
