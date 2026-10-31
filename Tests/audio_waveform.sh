#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
test_build_dir=$(mktemp -d /private/tmp/tgextra-waveform-tests.XXXXXX)
trap 'rm -rf "$test_build_dir"' EXIT
python3 - "$test_build_dir" <<'PY'
import math
from pathlib import Path
import struct
import sys
import wave
for name, amplitude in [('audio', 12000), ('silent', 0)]:
    with wave.open(str(Path(sys.argv[1]) / (name + '.wav')), 'wb') as audio:
        audio.setparams((1, 2, 16000, 0, 'NONE', 'not compressed'))
        audio.writeframes(b''.join(struct.pack('<h', round(amplitude * math.sin(2 * math.pi * 440 * i / 16000))) for i in range(32000)))
PY
clang -fobjc-arc -Werror -Wno-deprecated-declarations -DTGEXTRA_TESTING \
    -framework Foundation -framework AVFoundation -framework CoreMedia \
    Sources/tgapi/Logger/Logger.m Tests/audio_waveform.m -o "$test_build_dir/tests"
"$test_build_dir/tests" "$test_build_dir"
