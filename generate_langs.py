#!/usr/bin/env python3
"""Generate embedded Objective-C dictionaries from TGExtra translations."""
import argparse
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parent
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--bundle', type=Path, default=ROOT / 'TGExtra.bundle')
parser.add_argument('--output', type=Path, default=ROOT / 'Sources/tgapi/UI/EmbeddedLangs.h')
args = parser.parse_args()
if not args.bundle.is_dir():
    parser.error(f'Bundle not found: {args.bundle}')

out = ['#import <Foundation/Foundation.h>', '',
       'static inline NSDictionary *GetAllTranslations(NSString *code) {']
count = 0
# Preserve valid .strings escapes verbatim, including escaped quotation marks.
entry = re.compile(r'^\s*("(?:[^"\\]|\\.)*")\s*=\s*("(?:[^"\\]|\\.)*")\s*;\s*$')
for path in sorted(args.bundle.glob('*.lproj/Localizable.strings')):
    code = path.parent.stem
    out.extend([f'    if ([code isEqualToString:@"{code}"]) {{', '        return @{'])
    keys = set()
    for number, line in enumerate(path.read_text().splitlines(), 1):
        if not line.strip() or line.lstrip().startswith(('//', '/*', '*')):
            continue
        match = entry.fullmatch(line)
        if not match:
            raise SystemExit(f'{path}:{number}: invalid translation')
        key, value = match.groups()
        if key in keys:
            raise SystemExit(f'{path}:{number}: duplicate key {key}')
        keys.add(key)
        out.append(f'            @{key}: @{value},')
    out.extend(['        };', '    }'])
    count += 1
out.extend(['    return nil;', '}', ''])
args.output.parent.mkdir(parents=True, exist_ok=True)
args.output.write_text('\n'.join(out))
print(f'Generated embedded translations for {count} languages')
