#!/usr/bin/env python3
"""Check the original host fixture and the small generated policy views."""
import hashlib
import json
from pathlib import Path
import subprocess
import sys
import tempfile
from unittest.mock import patch
import zlib

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "Tools"))
from tl_schema import decode_schema
import update_telegram_api

fixture = ROOT / "Tests/Fixtures/TelegramApiSchema.zlib"
metadata = json.loads(fixture.with_suffix(".json").read_text())
assert hashlib.sha256(fixture.read_bytes()).hexdigest() == metadata["schema_sha256"]
schema = decode_schema(zlib.decompress(fixture.read_bytes()))
assert len(schema["constructors"]) > 1600 and len(schema["functions"]) > 800
assert not (ROOT / "Sources/tgapi/api_sources").exists(), "The full standalone API must not be bundled"
assert not list((ROOT / "Sources").rglob("*.tl"))
subprocess.run([sys.executable, str(ROOT / "Tools/update_telegram_api.py"), "--check"], check=True)
views = (ROOT / "Sources/tgapi/TL/ApiViews.swift").read_text()
assert "appendInt32" not in views and "parse_" not in views, "Views must not implement the wire protocol"
assert len(views) < 500_000, "Only policy-facing API views belong in the tweak"
assert "public " not in views, "Generated views are internal to the tweak"

# Test-only cases must not enter production, and nested source files must count.
with tempfile.TemporaryDirectory(prefix="tgextra-api-views-") as tmp:
    root = Path(tmp)
    sources = root / "Sources/tgapi"
    (sources / "TL").mkdir(parents=True)
    (sources / "UI").mkdir()
    (root / "Tests").mkdir()
    (sources / "Policy.swift").write_text("let value: Api.Bool = .boolTrue\n")
    (sources / "UI/Peer.swift").write_text("let value: Api.Peer = .peerUser\n")
    (sources / "TLMethodID.swift").write_text("")
    output = sources / "TL/ApiViews.swift"
    output.write_text("let stale: Api.User = .userEmpty\n")
    (root / "Tests/Case.swift").write_text("let value: Api.Bool = .boolFalse\n")
    with patch.object(update_telegram_api, "ROOT", root), patch.object(update_telegram_api, "OUTPUT", output):
        production = update_telegram_api.generate(schema)
        testing = update_telegram_api.generate(schema, include_tests=True)
    assert "case boolTrue" in production and "case peerUser(" in production
    assert "case boolFalse" not in production and "case boolFalse" in testing
    assert "enum User:" not in production, "Previous generated output must not feed generation"
    assert "public " not in production and "public " not in testing

    test_output = root / "TestViews.swift"
    subprocess.run([sys.executable, str(ROOT / "Tools/update_telegram_api.py"),
                    "--test-output", str(test_output)], check=True)
    assert test_output.read_text() == update_telegram_api.generate(schema, include_tests=True)
    assert (ROOT / "Sources/tgapi/TL/ApiViews.swift").read_text() == views
print(f"PASS original host schema: {len(schema['constructors'])} constructors, {len(schema['functions'])} methods; no bundled protocol")
