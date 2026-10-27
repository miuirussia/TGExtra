#!/usr/bin/env python3
"""Check the original host fixture and the small generated policy views."""
import hashlib
import json
from pathlib import Path
import subprocess
import sys
import zlib

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "Tools"))
from tl_schema import decode_schema

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
print(f"PASS original host schema: {len(schema['constructors'])} constructors, {len(schema['functions'])} methods; no bundled protocol")
