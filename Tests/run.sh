#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
python3 Tests/check_resources.py
python3 Tests/edit_badge_refresh.py
test_build_dir=$(mktemp -d /private/tmp/tgextra-tests.XXXXXX)
trap 'rm -rf "$test_build_dir"' EXIT
# Compile a stable snapshot so concurrent edits cannot invalidate compiler inputs.
cp -R Sources Tests "$test_build_dir/"
cd "$test_build_dir"
clang -fobjc-arc -DTGEXTRA_TESTING -c Tests/Support/TestSupport.m -o "$test_build_dir/support.o"
clang -fobjc-arc -DTGEXTRA_TESTING -c Sources/tgapi/DefaultsMigration.m -o "$test_build_dir/migration.o"
clang -fobjc-arc -c Sources/tgapi/FunctionHandler.m -o "$test_build_dir/handlers.o"
clang -fobjc-arc -c Sources/tgapi/GhostExceptions.m -o "$test_build_dir/exceptions.o"
clang -fobjc-arc -c Sources/tgapiC/Gzip.m -o "$test_build_dir/gzip.o"
clang -fobjc-arc -c Sources/tgapiC/HistoryAccount.m -o "$test_build_dir/history-account.o"
swiftc -whole-module-optimization -I Sources/tgapiC/include -I Tests/Support -module-cache-path "$test_build_dir/cache" \
    Sources/tgapi/api_sources/*.swift Sources/tgapi/TLParser.swift Tests/main.swift \
    "$test_build_dir"/*.o -lz -o "$test_build_dir/TGExtraTests"
"$test_build_dir/TGExtraTests"

"$test_build_dir/TGExtraTests" --restore
