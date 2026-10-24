#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
python3 Tests/check_resources.py
python3 Tests/check_api_schema.py
python3 Tests/settings_support_labels.py
python3 Tests/edit_badge_refresh.py
python3 Tests/rust_thunks.py
python3 Tests/rust_patching.py
python3 Tests/cyan_packaging.py
test_build_dir=$(mktemp -d /private/tmp/tgextra-tests.XXXXXX)
trap 'rm -rf "$test_build_dir"' EXIT
# Compile a stable snapshot so concurrent edits cannot invalidate compiler inputs.
cp -R Sources Tests "$test_build_dir/"
cd "$test_build_dir"
clang -fobjc-arc -DTGEXTRA_TESTING -c Tests/Support/TestSupport.m -o "$test_build_dir/support.o"
clang -fobjc-arc -DTGEXTRA_TESTING -c Sources/tgapi/DefaultsMigration.m -o "$test_build_dir/migration.o"
clang -fobjc-arc -c Sources/tgapi/FunctionHandler.m -o "$test_build_dir/handlers.o"
clang -fobjc-arc -Werror -DTGEXTRA_TESTING -c Sources/tgapi/RustBridge.m -o "$test_build_dir/rust-bridge.o"
clang -arch arm64e -fobjc-arc -Werror -DTGEXTRA_TESTING -fsyntax-only Sources/tgapi/RustBridge.m
clang -fobjc-arc -Werror -DTGEXTRA_TESTING -c Tests/rust_bridge.m -o "$test_build_dir/rust-bridge-tests.o"
clang -fobjc-arc -c Sources/tgapi/GhostExceptions.m -o "$test_build_dir/exceptions.o"
clang -fobjc-arc -c Sources/tgapiC/Gzip.m -o "$test_build_dir/gzip.o"
clang -fobjc-arc -c Sources/tgapiC/HistoryAccount.m -o "$test_build_dir/history-account.o"
clang -fobjc-arc -Werror -Wno-deprecated-declarations -DTGEXTRA_TESTING -ISources/tgapiC/include -c Sources/tgapi/ForwardCopy.m -o "$test_build_dir/forward-copy.o"
clang -fobjc-arc -Werror -DTGEXTRA_TESTING -ISources/tgapiC/include -c Tests/forward_copy.m -o "$test_build_dir/forward-copy-tests.o"
swiftc -whole-module-optimization -I Sources/tgapiC/include -I Tests/Support -module-cache-path "$test_build_dir/cache" \
    Sources/tgapi/api_sources/*.swift Sources/tgapi/TLParser.swift Sources/tgapi/ForwardCopy.swift Tests/content_settings.swift Tests/api_compatibility.swift Tests/forward_copy.swift Tests/message_protection.swift Tests/read_contents.swift Tests/own_user_accounts.swift Tests/rendered_messages.swift Tests/main.swift \
    "$test_build_dir"/*.o -lz -o "$test_build_dir/TGExtraTests"
"$test_build_dir/TGExtraTests"

"$test_build_dir/TGExtraTests" --restore
