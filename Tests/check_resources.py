#!/usr/bin/env python3
"""Check menu coverage, localization and request IDs against the host API."""
from pathlib import Path
import re
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parent.parent
menu = (ROOT / 'Sources/tgapi/UI/TGExtra.m').read_text()
start = menu.rindex('- (NSString *)switchKeyForIndexPath:')
keys = menu[start:]
keys = keys[keys.index('  case MISC:'):keys.index('  case FILE_FIXER:')]
rows = [int(row) for row in re.findall(r'case (\d+):', keys)]
count = re.search(r'case MISC:\s*return (\d+);', menu)
assert set(rows) == set(range(int(count[1]))), 'Every visible miscellaneous switch needs a settings key'
cell = menu[menu.index('  } else if (indexPath.section == MISC)'):]
cell = cell[:cell.index('  } else if (indexPath.section == FILE_FIXER)')]
assert set(map(int, re.findall(r'indexPath.row == (\d+)', cell))) == set(rows), 'Switch labels and settings keys must use the same rows'

pattern = re.compile(r'^\s*"((?:[^"\\]|\\.)*)"\s*=\s*"((?:[^"\\]|\\.)*)"\s*;\s*$', re.M)
english = dict(pattern.findall((ROOT / 'TGExtra.bundle/en.lproj/Localizable.strings').read_text()))
for path in (ROOT / 'TGExtra.bundle').glob('*.lproj/Localizable.strings'):
    entries = pattern.findall(path.read_text())
    assert len(entries) == len(dict(entries)), f'Duplicate translations in {path}'
    assert english.keys() <= dict(entries).keys(), f'Missing translations in {path}'
used = set()
for path in (ROOT / 'Sources/tgapi').rglob('*'):
    if path.suffix in ('.m', '.xm'):
        used.update(re.findall(r'(?:TGLoc|TGExtraLoc|localizedStringForKey:)\(?@"([^"]+)"', path.read_text()))
assert used <= english.keys(), f'Missing UI keys: {used - english.keys()}'

constants = (ROOT / 'Sources/tgapi/Constants.h').read_text()
api = (ROOT / 'Sources/tgapi/api_sources/Api43.swift').read_text()
for constant, function in {
    'kMessagesSendMedia': 'sendMedia', 'kMessagesSendMultiMedia': 'sendMultiMedia',
    'kMessagesUploadMedia': 'uploadMedia', 'kMessagesReadMessageContents': 'readMessageContents',
    'kChannelsReadMessageContents': 'readMessageContents', 'kGetSponsoredMessages': 'getSponsoredMessages',
    'kMessagesSetTypingAction': 'setTyping', 'kMessagesReadHistory': 'readHistory',
    'kStoriesReadStories': 'readStories', 'kSendScreenshotNotification': 'sendScreenshotNotification',
}.items():
    value = re.search(r'^#define ' + constant + r' (-?\d+)', constants, re.M)[1]
    constructors = re.findall(r'static func ' + function + r'\([^\n]*\n        let buffer = Buffer\(\)\n        buffer.appendInt32\((-?\d+)\)', api)
    assert value in constructors, f'{constant} is out of date with the bundled API'
for path in (ROOT / 'Sources').rglob('*'):
    if path.suffix in ('.h', '.m', '.xm', '.swift') and 'api_sources' not in path.parts:
        assert not re.search(r'kConfirmCalls|kDownloadSpeedBoost|kCustomStars|CONFIRM_CALLS|DOWNLOAD_BOOST|CUSTOM_STARS|MxApiCompat', path.read_text()), f'Excluded feature in {path}'
with tempfile.TemporaryDirectory() as tmp:
    output = Path(tmp) / 'EmbeddedLangs.h'
    subprocess.run(['python3', str(ROOT / 'generate_langs.py'), '--output', str(output)], check=True, capture_output=True)
    assert output.read_bytes() == (ROOT / 'Sources/tgapi/UI/EmbeddedLangs.h').read_bytes(), 'Embedded translations are stale'
print('PASS menu coverage, ten languages, bundled API request IDs and excluded features')
