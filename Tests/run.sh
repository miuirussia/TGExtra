#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
python3 Tools/build_payloads.py
python3 Tests/check_resources.py
python3 Tests/check_api_schema.py
python3 Tests/host_schema.py
python3 Tests/native_tl_profile.py
python3 Tests/settings_support_labels.py
python3 Tests/settings_menu.py
python3 Tests/settings_apply.py
python3 Tests/review_regressions.py
python3 Tests/review_fixes.py
python3 Tests/settings_persistence.py
python3 Tests/video_to_voice.py
bash Tests/round_video_recovery.sh
python3 Tests/video_preview.py
python3 Tests/double_tap_reactions.py
python3 Tests/recording_button.py
python3 Tests/recording_input_layout.py
python3 Tests/force_tlottie.py
python3 Tests/swiftgram_pro_ipatch.py
python3 Tests/edit_badge_refresh.py
python3 Tests/message_cleanup.py
python3 Tests/edit_history_diff.py
python3 Tests/paid_media_download.py
python3 Tests/paid_media_import.py
python3 Tests/paid_media_capture.py
python3 Tests/secret_chats.py
python3 Tests/paid_media_uikit.py
python3 Tests/rust_thunks.py
python3 Tests/rust_patching.py
python3 Tests/rust_portable.py
python3 Tests/ipatch_packaging.py
test_build_dir=$(mktemp -d /private/tmp/tgextra-tests.XXXXXX)
trap 'rm -rf "$test_build_dir"' EXIT
# Compile a stable snapshot so concurrent edits cannot invalidate compiler inputs.
cp -R Sources Tests Patches Tools "$test_build_dir/"
cd "$test_build_dir"
python3 Tools/update_telegram_api.py --test-output Sources/tgapi/TL/ApiViews.swift
python3 Tests/native_schema.py
for source in Tests/Fixtures/NativeTL/{TLObject,TLSchemaLoader,TLEngine}.m; do
    clang -O2 -fno-objc-arc -I Tests/Fixtures/NativeTL/include -c "$source" -o "$test_build_dir/native-$(basename "$source").o"
done
clang -O2 -c Tests/Fixtures/NativeTL/Schema.c -o "$test_build_dir/native-schema.o"
clang -O2 -Werror -DOriginal=TGEFixtureRawConstructor -c Patches/native-tl-v1/payloads/constructor.c -o "$test_build_dir/native-constructor-thunk.o"
clang -O2 -Werror -DOriginal=TGEFixtureRawResult -c Patches/native-tl-v1/payloads/result.c -o "$test_build_dir/native-result-thunk.o"
clang -fno-objc-arc -DTGEXTRA_TESTING -I Tests/Fixtures/NativeTL/include -c Tests/native_engine.m -o "$test_build_dir/native-engine-tests.o"
clang -fobjc-arc -DTGEXTRA_TESTING -c Tests/Support/TestSupport.m -o "$test_build_dir/support.o"
clang -fobjc-arc -DTGEXTRA_TESTING -c Sources/tgapi/DefaultsMigration.m -o "$test_build_dir/migration.o"
clang -fobjc-arc -DTGEXTRA_TESTING -c Sources/tgapi/Preferences.m -o "$test_build_dir/preferences.o"
clang -fobjc-arc -c Sources/tgapi/FunctionHandler.m -o "$test_build_dir/handlers.o"
clang -fobjc-arc -Werror -DTGEXTRA_TESTING -c Sources/tgapi/RustBridge.m -o "$test_build_dir/rust-bridge.o"
clang -arch arm64e -fobjc-arc -Werror -DTGEXTRA_TESTING -fsyntax-only Sources/tgapi/RustBridge.m
clang -fobjc-arc -Werror -DTGEXTRA_TESTING -c Tests/rust_bridge.m -o "$test_build_dir/rust-bridge-tests.o"
clang -fobjc-arc -c Sources/tgapi/GhostExceptions.m -o "$test_build_dir/exceptions.o"
clang -fobjc-arc -c Sources/tgapiC/Gzip.m -o "$test_build_dir/gzip.o"
clang -fobjc-arc -Werror -DTGEXTRA_TESTING -c Sources/tgapiC/HostTLSchema.m -o "$test_build_dir/host-tl-schema.o"
clang -O2 -fobjc-arc -Werror -DTGEXTRA_TESTING -c Sources/tgapiC/NativeTL.m -o "$test_build_dir/native-tl.o"
clang++ -fobjc-arc -Werror Tests/native_linkage.mm "$test_build_dir/native-tl.o" \
    -framework Foundation -o "$test_build_dir/NativeLinkageTests"
"$test_build_dir/NativeLinkageTests"
clang -fobjc-arc -c Sources/tgapiC/HistoryAccount.m -o "$test_build_dir/history-account.o"
clang -fobjc-arc -Werror -c Sources/tgapiC/MessageCleanup.m -o "$test_build_dir/message-cleanup.o"
clang -fobjc-arc -Werror -Wno-deprecated-declarations -DTGEXTRA_TESTING -ISources/tgapiC/include -c Sources/tgapi/ForwardCopy.m -o "$test_build_dir/forward-copy.o"
clang -fobjc-arc -Werror -DTGEXTRA_TESTING -ISources/tgapiC/include -c Tests/forward_copy.m -o "$test_build_dir/forward-copy-tests.o"
optimization=-Onone
if [[ "${1:-}" == "--benchmark" || "${1:-}" == "--native-benchmark" ]]; then optimization=-O; fi
swiftc -D TGEXTRA_TESTING "$optimization" -whole-module-optimization -I Sources/tgapiC/include -I Tests/Support -module-cache-path "$test_build_dir/cache" \
    Sources/tgapi/TL/*.swift Sources/tgapi/*.swift Sources/tgapi/UI/*.swift Tests/history_archive.swift Tests/round_video.swift Tests/paid_media.swift Tests/content_settings.swift Tests/api_compatibility.swift Tests/forward_copy.swift Tests/message_protection.swift Tests/read_contents.swift Tests/own_user_accounts.swift Tests/rendered_messages.swift Tests/host_runtime.swift Tests/portability.swift Tests/codec_benchmark.swift Tests/native_engine.swift Tests/main.swift \
    "$test_build_dir"/*.o -lz -lsqlite3 -Xlinker -export_dynamic -o "$test_build_dir/TGExtraTests"
export TGEXTRA_TL_SCHEMA="$test_build_dir/Tests/Fixtures/TelegramApiSchema.zlib"
if [[ "${1:-}" == "--benchmark" || "${1:-}" == "--native-benchmark" ]]; then
    "$test_build_dir/TGExtraTests" "$1"
    exit
fi
"$test_build_dir/TGExtraTests"

"$test_build_dir/TGExtraTests" --native
"$test_build_dir/TGExtraTests" --restore
TGEXTRA_TL_SCHEMA=/dev/null "$test_build_dir/TGExtraTests" --no-schema
