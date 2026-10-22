#!/usr/bin/env python3
"""Regenerate the tweak's standalone Swift API from a local Telegram-iOS schema."""
import argparse
import hashlib
import io
import json
import os
from pathlib import Path
import re
import subprocess
import tarfile
import tempfile

ROOT = Path(__file__).resolve().parent.parent
# Last class-based SwiftTL generator. The host now uses an ObjC-backed engine;
# keeping the standalone Swift codec avoids duplicate ObjC classes in the app.
GENERATOR_REVISION = "8947c9971fd4c494aaa6b864a637ed14a07d5a4a"


def patch_content_flags(contents):
    # Preserve the existing tweak's codec patches, independent of file splits.
    noforwards = {"channel": 27, "chat": 25, "message": 26, "storyItem": 10}
    restrictions = {"channel": 9, "message": 22, "user": 18}

    def patch(match):
        name, body = match.group(1), match.group(0)
        if name in noforwards:
            bit = noforwards[name]
            anchor = "            _1 = reader.readInt32()\n"
            assert body.count(anchor) == 1
            body = body.replace(anchor, anchor +
                f"            _1 = _1.map {{ $0 & ~(1 << {bit}) }} // TGExtra: clear noforwards:flags.{bit}\n")
        if name in restrictions:
            bit = restrictions[name]
            pattern = r"( +)(_(\d+)) = Api.parseVector\(reader, elementSignature: 0, elementType: Api.RestrictionReason.self\)\n"

            def clear_reason(field):
                indent, variable = field.group(1), field.group(2)
                return field.group(0) + (
                    f"{indent}if {variable} != nil {{\n"
                    f"{indent}    _1 = _1.map {{ $0 & ~(1 << {bit}) }} // TGExtra: clear restriction_reason after reading it\n"
                    f"{indent}    {variable} = nil\n{indent}}}\n")

            body, count = re.subn(pattern, clear_reason, body)
            assert count == 1
        return body

    return re.sub(r"public static func parse_(\w+)\(_ reader: BufferReader\).*?\n        }",
                  patch, contents, flags=re.S)


def arrange_sources(generated, previous):
    # Keep existing types in their files so schema additions do not move tens
    # of thousands of unrelated lines. New types share a new numbered file.
    def blocks(contents):
        return re.findall(r"^public extension Api[^\n]* \{.*?(?=^public extension Api|\Z)",
                          contents, flags=re.M | re.S)

    def type_name(block):
        match = re.match(r"public extension (Api[\w.]*) \{\n    (?:indirect )?enum (\w+)", block)
        return f"{match[1]}.{match[2]}" if match else None

    locations = {}
    functions_file = None
    for filename, contents in previous.items():
        if filename == "Api0.swift":
            continue
        for block in blocks(contents):
            if block.startswith("public extension Api.functions."):
                functions_file = filename
            else:
                locations[type_name(block)] = filename
    assert functions_file is not None
    added_file = f"Api{max(int(re.search(r'\d+', name)[0]) for name in previous) + 1}.swift"
    grouped = {}
    for filename, contents in generated.items():
        if filename == "Api0.swift":
            continue
        for block in blocks(contents):
            target = functions_file if block.startswith("public extension Api.functions.") else locations.get(type_name(block), added_file)
            grouped.setdefault(target, []).append(block)
    result = {"Api0.swift": generated["Api0.swift"]}
    for filename, values in grouped.items():
        if filename != functions_file:
            values.sort(key=type_name)
        result[filename] = "".join(values)
    return result


def update(checkout):
    source = checkout / "submodules/TelegramApi/swift_scheme.tl"
    schema = source.read_bytes()
    revision = subprocess.check_output(
        ["git", "-C", str(checkout), "rev-parse", "HEAD"], text=True
    ).strip()
    archive = subprocess.check_output([
        "git", "-C", str(checkout), "archive", GENERATOR_REVISION,
        "build-system/SwiftTL",
    ])
    with tempfile.TemporaryDirectory(prefix="tgextra-api-") as scratch:
        scratch = Path(scratch)
        with tarfile.open(fileobj=io.BytesIO(archive)) as package:
            package.extractall(scratch, filter="data")
        env = dict(os.environ, CLANG_MODULE_CACHE_PATH=str(scratch / "module-cache"))
        build = [
            "swift", "build", "--package-path", str(scratch / "build-system/SwiftTL"),
            "--scratch-path", str(scratch / "build"), "--cache-path", str(scratch / "cache"),
            "--config-path", str(scratch / "config"), "--security-path", str(scratch / "security"),
            "-c", "release",
        ]
        subprocess.run(build, env=env, check=True)
        binaries = subprocess.check_output(build + ["--show-bin-path"], env=env, text=True).strip()
        schema_path = scratch / "swift_scheme.tl"
        schema_path.write_bytes(schema)
        output = scratch / "generated"
        subprocess.run([str(Path(binaries) / "SwiftTL"), str(schema_path), str(output)], check=True)

        registry = output / "Api0.swift"
        contents = registry.read_text()
        # Tweak-specific safeguards used by opaque-tail recovery.
        anchor = "public extension Api {\n"
        assert contents.count(anchor) == 1
        contents = contents.replace(anchor, anchor + """    internal static func isKnownConstructor(_ signature: Int32) -> Swift.Bool {
        return parsers[signature] != nil
    }

""")
        anchor = "if let count = reader.readInt32() {"
        assert contents.count(anchor) == 1
        contents = contents.replace(anchor, "if let count = reader.readInt32(), count >= 0 {")
        registry.write_text(contents)
        destination = ROOT / "Sources/tgapi/api_sources"
        previous = {p.name: p.read_text() for p in destination.glob("Api*.swift")}
        generated = arrange_sources(
            {p.name: patch_content_flags(p.read_text()) for p in output.glob("Api*.swift")}, previous)
        assert len(generated) > 1 and "Api0.swift" in generated
        assert "enum UserFull" in "".join(generated.values())

        for old in destination.glob("Api*.swift"):
            if re.fullmatch(r"Api\d+\.swift", old.name) and old.name not in generated:
                old.unlink()
        for name, data in generated.items():
            (destination / name).write_text(data)

    snapshot = ROOT / "Tools/TelegramApi"
    snapshot.mkdir(parents=True, exist_ok=True)
    (snapshot / "swift_scheme.tl").write_bytes(schema)
    metadata = {
        "source_revision": revision,
        "source_app_version": json.loads((checkout / "versions.json").read_text())["app"],
        "schema_sha256": hashlib.sha256(schema).hexdigest(),
        "generator_revision": GENERATOR_REVISION,
    }
    (snapshot / "version.json").write_text(json.dumps(metadata, indent=2) + "\n")
    print(f"Updated {len(generated)} Swift files from Telegram-iOS {revision}")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("checkout", nargs="?", type=Path, default=Path.home() / "Projects/Telegram-iOS")
    update(parser.parse_args().checkout.expanduser().resolve())
