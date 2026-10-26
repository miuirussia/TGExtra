import Foundation
import tgapiC

// Swiftgram master e3a392272b182dbf975d4ac5fc33b40a5954d749:
// Swiftgram/SGStatus/Sources/SGStatus.swift, built in TelegramUIPreferences.
// Postbox decodes this through Decodable's witness, including shared settings
// used by the paywall, immediateSGStatus, ephemeralStatus and notification cache.
private let swiftgramStatusType: Decodable.Type? = {
    guard let type = _typeByName("21TelegramUIPreferences8SGStatusV") as? Decodable.Type else {
        return nil
    }
    func compatible<T>(_: T.Type) -> Bool {
        guard _isPOD(T.self), MemoryLayout<T>.size == MemoryLayout<Int64>.size,
            MemoryLayout<T>.alignment == MemoryLayout<Int64>.alignment else { return false }
        // Equal size/alignment alone also accepts Double, UInt64 and wrappers.
        // Missing reflection metadata must leave the host untouched as well.
        return TGExtraSwiftgramStatusHasExpectedField(
            unsafeBitCast(T.self, to: UnsafeRawPointer.self),
            unsafeBitCast(Int64.self, to: UnsafeRawPointer.self))
    }
    return _openExistential(type, do: compatible) ? type : nil
}()

// The replacement has the same one-Int64 layout and decoding behavior as
// SGStatus. Using a Swift-generated witness preserves the Swift calling ABI.
private struct SwiftgramStatusOverride: Decodable {
    let status: Int64

    private enum Keys: String, CodingKey { case status }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: Keys.self)
        let value = try container.decodeIfPresent(Int64.self, forKey: .status) ?? 1
        status = UserDefaults.standard.bool(forKey: "TGExtraSwiftgramPro") ? max(2, value) : value
    }
}

private func decodingWitness(_ type: Decodable.Type) -> UnsafeRawPointer {
    // A single-protocol existential metatype contains metadata and its witness
    // table. Decodable has one requirement: init(from:), at table slot 1.
    return unsafeBitCast(type, to: (UnsafeRawPointer, UnsafeRawPointer).self).1
}

private let swiftgramProInstalled: Bool = {
    guard let type = swiftgramStatusType else { return false }
    return TGExtraReplaceSwiftgramStatusWitness(
        decodingWitness(type), decodingWitness(SwiftgramStatusOverride.self))
}()

@_cdecl("TGExtraSwiftgramProAvailable")
func tgextraSwiftgramProAvailable() -> Bool {
    // Probe the actual installation, including memory protection and arm64e
    // requirements. The replacement preserves status while the option is off.
    return swiftgramProInstalled
}

@_cdecl("TGExtraInstallSwiftgramPro")
func tgextraInstallSwiftgramPro() -> Bool {
    return swiftgramProInstalled
}
