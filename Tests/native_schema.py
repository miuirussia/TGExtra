#!/usr/bin/env python3
"""Emit test-only native schema data in the isolated test build directory."""
from pathlib import Path
root = Path(__file__).resolve().parent
blob = (root / "Fixtures/TelegramApiSchema.zlib").read_bytes()
(root / "Fixtures/NativeTL/Schema.c").write_text(
    "#include <stdint.h>\nconst uint8_t TLApiSchemaCompressed[] = {" + ",".join(map(str, blob)) +
    "};\nconst uint32_t TLApiSchemaCompressedLength = " + str(len(blob)) + ";\n")
