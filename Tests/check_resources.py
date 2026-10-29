#!/usr/bin/env python3
"""Check menu coverage, localization and request IDs against the host API."""
from pathlib import Path
import re
import subprocess
import tempfile
import sys
import zlib

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / 'Tools'))
from tl_schema import decode_schema
menu = (ROOT / 'Sources/tgapi/UI/TGExtra.m').read_text()
rows = (ROOT / 'Sources/tgapi/UI/SettingsRows.m').read_text()
expected_features = {
    'kDisableAllAds', 'kDisableForwardRestriction', 'kAntiRevoke', 'kAntiAutoDelete',
    'kDisableScreenshotNotification', 'kAntiSelfDestruct', 'kAntiEdit',
    'kHideDisappearingLabel', 'kVideoToVoice', 'kIgnorePrivateChatCopyProtection',
    'kDisableDoubleTapReactions', 'kHideRecordingButton', 'kForceTLottie',
}
categories = rows[rows.index('+ (NSArray<TGExtraSettingRow *> *)featureRowsForSection:'):rows.index('+ (TGExtraSettingRow *)rowForSection:')]
feature_keys = re.findall(r'rowWithKey:(k\w+)', categories)
assert set(feature_keys) == expected_features, 'Keep every existing feature in the categorized menu'
assert len(feature_keys) == len(expected_features), 'Each feature must appear in exactly one category'
for section in ('MESSAGE_HISTORY', 'CONTENT_ACCESS', 'MEDIA', 'INTERFACE'):
    assert f'@({section}): @[' in categories, f'Empty category: {section}'
    assert f'TGLoc(@"{section}_SECTION_HEADER")' in menu, f'Missing category heading: {section}'
preferences = (ROOT / 'Sources/tgapi/Preferences.m').read_text()
switch_keys = set(re.findall(r'rowWithKey:(\w+)', rows)) - {'NSString'}
assert all(key in preferences for key in switch_keys), 'Every switch needs durable storage'

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
        if path.name == 'SettingsRows.m':
            used.update(re.findall(r'(?:title|subtitle):@"([^"]+)"', path.read_text()))
assert used <= english.keys(), f'Missing UI keys: {used - english.keys()}'

api = decode_schema(zlib.decompress((ROOT / 'Tests/Fixtures/TelegramApiSchema.zlib').read_bytes()))
method_ids = (ROOT / 'Sources/tgapi/TLMethodID.swift').read_text()
assert not re.search(r'Int32\s*=\s*-?\d+', method_ids), 'Production method IDs must come from the host'
methods = set(re.findall(r'case \w+ = "([^"]+)"', method_ids))
assert methods and methods <= {f['name'] for f in api['functions']}, 'Named methods must exist in the reference schema'
for path in (ROOT / 'Sources').rglob('*'):
    if path.suffix in ('.h', '.m', '.xm', '.swift'):
        if path.name != 'TLMethodID.swift':
            literals = set(re.findall(r'"(\w+\.\w+)"', path.read_text()))
            assert not literals & {f['name'] for f in api['functions']}, f'Method names must come from TLMethodID.swift: {path}'
        assert not re.search(r'kConfirmCalls|kDownloadSpeedBoost|kCustomStars|CONFIRM_CALLS|DOWNLOAD_BOOST|CUSTOM_STARS|MxApiCompat', path.read_text()), f'Excluded feature in {path}'
with tempfile.TemporaryDirectory() as tmp:
    output = Path(tmp) / 'EmbeddedLangs.h'
    subprocess.run(['python3', str(ROOT / 'generate_langs.py'), '--output', str(output)], check=True, capture_output=True)
    assert output.read_bytes() == (ROOT / 'Sources/tgapi/UI/EmbeddedLangs.h').read_bytes(), 'Embedded translations are stale'
print('PASS menu coverage, ten languages, host API request IDs and excluded features')
