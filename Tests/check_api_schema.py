#!/usr/bin/env python3
"""Check the complete generated API against the pinned host TL schema."""
import hashlib
import json
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parent.parent
snapshot = ROOT / "Tools/TelegramApi"
schema = (snapshot / "swift_scheme.tl").read_text()
version = json.loads((snapshot / "version.json").read_text())
assert hashlib.sha256(schema.encode()).hexdigest() == version["schema_sha256"], "Schema snapshot changed without regeneration"
files = {p.name: p.read_text() for p in (ROOT / "Sources/tgapi/api_sources").glob("Api*.swift")}
registry = {
    (typename.removeprefix("Api."), name): int(signature) & 0xFFFFFFFF
    for signature, typename, name in re.findall(
        r"dict\[(-?\d+)\] = \{ return (Api\.[\w.]+)\.parse_(\w+)\(\$0\) }", files["Api0.swift"])
}
fields = {}
functions = {}
for contents in files.values():
    for block in re.findall(r"^public extension (Api[\w.]*) \{\n(.*?)(?=^public extension Api|\Z)", contents, re.M | re.S):
        namespace, body = block
        if namespace.startswith("Api.functions."):
            function = re.search(r"static func (\w+)\(([^\n]*)\).*?buffer.appendInt32\((-?\d+)\)", body, re.S)
            assert function, f"Unrecognized function in {namespace}"
            functions[namespace.removeprefix("Api.functions.") + "." + function[1]] = (
                int(function[3]) & 0xFFFFFFFF, re.findall(r"(?:^|, )`?(\w+)`?:", function[2]))
            continue
        enum = re.match(r"    (?:indirect )?enum (\w+)", body)
        if not enum:
            continue
        typename = namespace.removeprefix("Api").lstrip(".")
        typename = (typename + "." if typename else "") + enum[1]
        for name, payload in re.findall(r"public class Cons_(\w+): TypeConstructorDescription \{(.*?)\n        }", body, re.S):
            fields[typename, name] = re.findall(r"public var `(\w+)`|public var (\w+):", payload)
            fields[typename, name] = [escaped or plain for escaped, plain in fields[typename, name]]


def camel(name):
    first, *rest = name.split("_")
    return first + "".join(part[:1].upper() + part[1:] for part in rest)


constructors, methods = schema.split("---functions---")
constructor_count = function_count = 0
for section, is_function in [(constructors, False), (methods, True)]:
    for name, signature, arguments, result in re.findall(
            r"^([\w.]+)#([a-f0-9]+) (.*?)= ([\w.<>!]+);$", section, re.M):
        if name in {"true", "vector", "error", "null", "initConnection"} or name.startswith("invoke"):
            continue  # MTProto primitives and generic wrappers are not generated Api types.
        expected = [camel(field) for field, kind in re.findall(r"(\w+):([^ ]+)", arguments)
                    if not kind.endswith("?true")]
        if is_function:
            assert name in functions, f"Missing function: {name}"
            actual_id, actual_fields = functions[name]
            function_count += 1
        else:
            key = (result, name.split(".")[-1])
            assert key in registry, f"Missing constructor: {name}"
            actual_id, actual_fields = registry[key], fields.get(key, [])
            constructor_count += 1
        assert actual_id == int(signature, 16), f"Outdated constructor ID: {name}"
        assert actual_fields == expected, f"Outdated fields: {name}: {actual_fields} != {expected}"

assert constructor_count > 1600 and function_count > 800, "Incomplete schema check"
print(f"PASS Telegram {version['source_app_version']} schema: {constructor_count} constructors, {function_count} functions")
