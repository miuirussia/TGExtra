#!/usr/bin/env python3
"""Exercise discovery in a loaded Mach-O and reject damaged schema streams."""
from pathlib import Path
import subprocess
import sys
import tempfile
import zipfile
import zlib

ROOT = Path(__file__).resolve().parent.parent
fixture = (ROOT / "Tests/Fixtures/TelegramApiSchema.zlib").read_bytes()
image = zlib.decompress(fixture)
with tempfile.TemporaryDirectory(prefix="tgextra-host-schema-") as tmp:
    tmp = Path(tmp)
    # Put the actual IPA table in __TEXT, as it is in TelegramCoreFramework.
    source = f'''#import <Foundation/Foundation.h>
#import "{ROOT / 'Sources/tgapiC/HostTLSchema.m'}"
@interface TLObject : NSObject @end
@implementation TLObject @end
__attribute__((used, section("__TEXT,__const")))
const uint8_t fixture[] = {{ {','.join(str(v) for v in fixture)} }};
int main(int argc, char **argv) {{
    @autoreleasepool {{
        NSData *discovered = TGExtraHostTLSchema();
        NSCAssert(discovered.length == {len(image)}, @"Find original table in the loaded image");
        NSCAssert(!memcmp(discovered.bytes, "TLS1", 4), @"Original TLS1 image");
        NSCAssert(TGExtraHostTLSchema() == discovered, @"Discovery is cached");
        NSCAssert(schemaInBytes(fixture, sizeof(fixture) - 1) == nil, @"Reject truncated streams");
        NSMutableData *damaged = [NSMutableData dataWithBytes:fixture length:sizeof(fixture)];
        ((uint8_t *)damaged.mutableBytes)[damaged.length - 1] ^= 1;
        NSCAssert(schemaInBytes(damaged.bytes, damaged.length) == nil, @"Reject checksum corruption");
        NSMutableData *duplicate = [NSMutableData dataWithBytes:fixture length:sizeof(fixture)];
        [duplicate appendBytes:fixture length:sizeof(fixture)];
        NSCAssert(schemaInBytes(duplicate.bytes, duplicate.length) == nil, @"Reject ambiguous tables");
        uint8_t junk[80] = {{0x78, 0x9c}};
        NSCAssert(schemaInBytes(junk, sizeof(junk)) == nil, @"Ignore unrelated zlib signatures");
        for (int i = 1; i < argc; i++) {{
            NSData *binary = [NSData dataWithContentsOfFile:@(argv[i])];
            NSData *actual = schemaInBytes(binary.bytes, binary.length);
            NSCAssert([actual isEqual:discovered], @"IPA supplies the original schema intact");
        }}
        puts("PASS native host schema discovery, caching, truncation, checksum and ambiguity");
    }}
}}
'''
    (tmp / "main.m").write_text(source)
    subprocess.run(["clang", "-fobjc-arc", "-Werror", str(tmp / "main.m"),
                    str(ROOT / "Sources/tgapiC/Gzip.m"), "-framework", "Foundation", "-lz", "-o", str(tmp / "test")], check=True)
    binaries = []
    for index, ipa in enumerate(sys.argv[1:]):
        with zipfile.ZipFile(ipa) as archive:
            names = [n for n in archive.namelist() if n.endswith("/TelegramCoreFramework.framework/TelegramCoreFramework")]
            assert len(names) == 1, "Expected one TelegramCoreFramework in the reference IPA"
            path = tmp / f"client-{index}"
            path.write_bytes(archive.read(names[0]))
            binaries.append(str(path))
    subprocess.run([str(tmp / "test"), *binaries], check=True)
    if binaries:
        print(f"PASS original schema extraction from {len(binaries)} reference IPAs")
