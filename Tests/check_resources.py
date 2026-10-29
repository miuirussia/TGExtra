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
    'kDisableDoubleTapReactions', 'kForceTLottie',
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

constants = (ROOT / 'Sources/tgapi/Constants.h').read_text()
api = decode_schema(zlib.decompress((ROOT / 'Tests/Fixtures/TelegramApiSchema.zlib').read_bytes()))
for constant, function in {
    'kMessagesSendMedia': 'sendMedia', 'kMessagesSendMultiMedia': 'sendMultiMedia',
    'kMessagesUploadMedia': 'uploadMedia', 'kMessagesReadMessageContents': 'readMessageContents',
    'kChannelsReadMessageContents': 'readMessageContents', 'kGetSponsoredMessages': 'getSponsoredMessages',
    'kMessagesSetTypingAction': 'setTyping', 'kMessagesReadHistory': 'readHistory',
    'kMessagesReadMentions': 'readMentions', 'kMessagesReadReactions': 'readReactions',
    'kStoriesReadStories': 'readStories', 'kSendScreenshotNotification': 'sendScreenshotNotification',
    'kGetAppConfig': 'getAppConfig',
}.items():
    value = re.search(r'^#define ' + constant + r' (-?\d+)', constants, re.M)[1]
    constructors = [f['id'] for f in api['functions'] if f['name'].endswith('.' + function)]
    assert int(value) & 0xffffffff in constructors, f'{constant} is out of date with the host API'
for path in (ROOT / 'Sources').rglob('*'):
    if path.suffix in ('.h', '.m', '.xm', '.swift'):
        assert not re.search(r'kConfirmCalls|kDownloadSpeedBoost|kCustomStars|CONFIRM_CALLS|DOWNLOAD_BOOST|CUSTOM_STARS|MxApiCompat', path.read_text()), f'Excluded feature in {path}'
with tempfile.TemporaryDirectory() as tmp:
    output = Path(tmp) / 'EmbeddedLangs.h'
    subprocess.run(['python3', str(ROOT / 'generate_langs.py'), '--output', str(output)], check=True, capture_output=True)
    assert output.read_bytes() == (ROOT / 'Sources/tgapi/UI/EmbeddedLangs.h').read_bytes(), 'Embedded translations are stale'
print('PASS menu coverage, ten languages, host API request IDs and excluded features')
