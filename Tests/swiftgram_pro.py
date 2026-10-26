#!/usr/bin/env python3
"""Exercise the production Swift witness replacement across optimized modules."""
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parent.parent

# Same layout and decoding rules as Swiftgram's SGStatus. A separate module and
# a generic decoding boundary model TelegramUIPreferences -> Postbox dispatch.
HOST = r'''
import Foundation
public struct SGStatus: Codable {
    public var status: Int64
    enum Keys: String, CodingKey { case status }
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: Keys.self)
        status = try container.decodeIfPresent(Int64.self, forKey: .status) ?? 1
    }
}
'''
DECODER = r'''
import Foundation
public func decode<T: Decodable>(_ type: T.Type, _ data: Data) throws -> T {
    return try JSONDecoder().decode(type, from: data)
}
'''
TEST = r'''
import Foundation
import TelegramUIPreferences
import PostboxFixture

func setEnabled(_ enabled: Bool) {
    UserDefaults.standard.setVolatileDomain(["TGExtraSwiftgramPro": enabled], forName: UserDefaults.argumentDomain)
}
func read(_ json: String) throws -> Int64 {
    return try decode(SGStatus.self, Data(json.utf8)).status
}
func check(_ condition: @autoclosure () throws -> Bool, _ message: String) rethrows {
    let passed = try condition()
    if !passed { fatalError(message) }
}
struct OtherStatus: Decodable { let status: Int64 }

setEnabled(false)
try check(read("{\"status\":1}") == 1, "Unmodified fixture")
check(tgextraSwiftgramProAvailable(), "Discover stripped host type by its real module/name")
check(tgextraInstallSwiftgramPro(), "Install actual Swift witness replacement")
check(tgextraInstallSwiftgramPro(), "Installation is idempotent")
for enabled in [false, true, false, true] {
    setEnabled(enabled)
    for value: Int64 in [Int64.min, -1, 0, 1, 2, 3, Int64.max] {
        try check(read("{\"status\":\(value)}") == (enabled ? max(2, value) : value),
                  "Apply local override while preserving existing higher statuses")
    }
    for json in ["{}", "{\"status\":null}"] {
        try check(read(json) == (enabled ? 2 : 1), "Preserve Swiftgram's fallback")
    }
    for json in ["{\"status\":\"1\"}", "{\"status\":[]}", "[]", "invalid"] {
        do {
            _ = try read(json)
            preconditionFailure("Malformed settings must still fail decoding")
        } catch {}
    }
    let other = try decode(OtherStatus.self, Data("{\"status\":1}".utf8))
    check(other.status == 1, "Other types with status fields are untouched")
}
// No persistent preferences or application settings are written by this test.
UserDefaults.standard.removeVolatileDomain(forName: UserDefaults.argumentDomain)
print("PASS Swiftgram Pro: optimized cross-module decoding, off/on/off, fallback, malformed data, isolation")
'''
UNAVAILABLE = r'''
import Foundation
precondition(!tgextraSwiftgramProAvailable())
precondition(!tgextraInstallSwiftgramPro())
print("PASS Swiftgram Pro: unsupported host/layout is left untouched")
'''
BOOTSTRAP = r'''
import Foundation
import TelegramUIPreferences
import PostboxFixture
let value = try decode(SGStatus.self, Data("{\"status\":1}".utf8))
if value.status != 2 { fatalError("The real constructor must install before host settings are decoded") }
print("PASS Swiftgram Pro: installation before main with the preference enabled")
'''

with tempfile.TemporaryDirectory(prefix='tgextra-swiftgram-pro-') as tmp:
    work = Path(tmp)
    include = str(ROOT / 'Sources/tgapiC/include')

    def run(*args):
        subprocess.run(args, cwd=work, check=True)

    run('clang', '-fobjc-arc', '-Werror', '-DTGEXTRA_TESTING', '-I', include,
        '-c', str(ROOT / 'Sources/tgapi/SwiftgramPro.m'), '-o', 'bridge.o')
    (work / 'Decoder.swift').write_text(DECODER)
    run('swiftc', '-O', '-emit-library', '-emit-module', '-module-name', 'PostboxFixture',
        'Decoder.swift', '-o', 'libPostboxFixture.dylib')

    def executable(source, *libraries, arguments=()):
        (work / 'main.swift').write_text(source)
        run('swiftc', '-O', '-I', include, '-I', tmp, '-L', tmp,
            '-Xlinker', '-rpath', '-Xlinker', tmp,
            str(ROOT / 'Sources/tgapi/SwiftgramPro.swift'), 'main.swift', 'bridge.o',
            *libraries, '-o', 'tests')
        run(str(work / 'tests'), *arguments)

    executable(UNAVAILABLE)
    (work / 'Host.swift').write_text(HOST)
    run('swiftc', '-O', '-emit-library', '-emit-module', '-module-name', 'TelegramUIPreferences',
        'Host.swift', '-o', 'libTelegramUIPreferences.dylib')
    # Runtime type lookup must also work without exported host Swift symbols.
    run('strip', '-x', 'libTelegramUIPreferences.dylib')
    executable(TEST, '-lTelegramUIPreferences', '-lPostboxFixture')
    run('clang', '-fobjc-arc', '-Werror', '-I', include,
        '-c', str(ROOT / 'Sources/tgapi/SwiftgramPro.m'), '-o', 'bridge.o')
    executable(BOOTSTRAP, '-lTelegramUIPreferences', '-lPostboxFixture',
               arguments=('-TGExtraSwiftgramPro', 'YES'))
    (work / 'Host.swift').write_text('public struct SGStatus: Decodable { let status: Int64; let extra: Int64 }')
    run('swiftc', '-O', '-emit-library', '-emit-module', '-module-name', 'TelegramUIPreferences',
        'Host.swift', '-o', 'libTelegramUIPreferences.dylib')
    executable('import TelegramUIPreferences\n' + UNAVAILABLE, '-lTelegramUIPreferences')
