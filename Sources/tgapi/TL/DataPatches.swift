import Foundation

struct TLFlagLocation: Equatable {
    let field: String
    let bit: Int
    var mask: Int32 { Int32(1) << bit }
}

enum TLFlag: String {
    case noForwards = "noforwards"
    case mediaUnread = "media_unread"
    case noForwardsMyEnabled = "noforwards_my_enabled"
    case noForwardsPeerEnabled = "noforwards_peer_enabled"

    func location(in record: TLRecord) -> TLFlagLocation? {
        let constructor = record.typeName + "." + record.constructorName
        switch self {
        case .noForwards:
            switch constructor {
            case "Chat.channel": return TLFlagLocation(field: "flags", bit: 27)
            case "Chat.chat": return TLFlagLocation(field: "flags", bit: 25)
            case "Message.message", "Updates.updateShortMessage", "Updates.updateShortChatMessage":
                return TLFlagLocation(field: "flags", bit: 26)
            case "StoryItem.storyItem": return TLFlagLocation(field: "flags", bit: 10)
            default: return nil
            }
        case .mediaUnread:
            guard ["Message.message", "Updates.updateShortMessage", "Updates.updateShortChatMessage",
                   "Updates.updateShortSentMessage"].contains(constructor) else { return nil }
            return TLFlagLocation(field: "flags", bit: 5)
        case .noForwardsMyEnabled, .noForwardsPeerEnabled:
            guard constructor == "UserFull.userFull" else { return nil }
            return TLFlagLocation(field: "flags2", bit: self == .noForwardsMyEnabled ? 23 : 24)
        }
    }
}

struct TLFieldChange: Equatable, CustomStringConvertible {
    let path: String
    let before: String
    let after: String
    let presenceFlag: TLFlagLocation?
    let rule: String?

    var description: String {
        let presence = presenceFlag.map { " [\($0.field).\($0.bit)]" } ?? ""
        let cause = rule.map { " {\($0)}" } ?? ""
        return "\(path): \(before) → \(after)\(presence)\(cause)"
    }
}

struct TLDataPatch {
    let record: TLRecord
    let rule: String?
    init(_ record: TLRecord, rule: String? = nil) { self.record = record; self.rule = rule }

    @discardableResult
    func clearFlag(_ flag: TLFlag) -> Bool {
        guard let location = flag.location(in: record),
              let flags = record[location.field] as? Int32, flags & location.mask != 0 else { return false }
        record.set(location.field, flags & ~location.mask)
        report(flag.rawValue, before: "true", after: "false", presence: location)
        return true
    }

    @discardableResult
    func removeOptionalField(_ name: String) -> Bool {
        guard let location = presenceFlag(for: name),
              let flags = record[location.field] as? Int32 else { return false }
        let previous = record[name]
        guard previous != nil || flags & location.mask != 0 else { return false }
        record.set(location.field, flags & ~location.mask)
        record.set(name, Optional<Int32>.none)
        report(name, before: Self.describe(previous), after: "absent", presence: location)
        return true
    }

    @discardableResult
    func setOptionalField<T: TLValue>(_ name: String, _ value: T) -> Bool {
        let raw = value.tlValue
        if raw is NSNull { return removeOptionalField(name) }
        guard let location = presenceFlag(for: name),
              let flags = record[location.field] as? Int32 else { return false }
        let previous = record[name]
        guard !Self.equal(previous, raw) || flags & location.mask == 0 else { return false }
        record.set(location.field, flags | location.mask)
        record.set(name, value)
        report(name, before: Self.describe(previous), after: Self.describe(raw), presence: location)
        return true
    }

    @discardableResult
    func replaceField<T: TLValue>(_ name: String, _ value: T) -> Bool {
        guard let descriptor = record.descriptor, let index = descriptor.fieldIndices[name] else { return false }
        let field = descriptor.fields[index]
        if field.flagsIndex >= 0 { return setOptionalField(name, value) }
        let raw = value.tlValue
        let replacement: Any? = raw is NSNull ? nil : raw
        let previous = record[name]
        guard !Self.equal(previous, replacement) else { return false }
        record.set(name, value)
        report(name, before: Self.describe(previous), after: Self.describe(replacement), presence: nil)
        return true
    }

    func presenceFlag(for name: String) -> TLFlagLocation? {
        guard let descriptor = record.descriptor,
              let index = descriptor.fieldIndices[name] else { return nil }
        let field = descriptor.fields[index]
        guard field.flagsIndex >= 0 else { return nil }
        return TLFlagLocation(field: descriptor.fields[field.flagsIndex].name, bit: field.flagBit)
    }

    private func report(_ name: String, before: String, after: String, presence: TLFlagLocation?) {
        record.recordChange(TLFieldChange(path: record.typeName + "." + record.constructorName + "." + name,
                                         before: before, after: after, presenceFlag: presence, rule: rule))
    }

    private static func equal(_ lhs: Any?, _ rhs: Any?) -> Bool {
        switch (lhs, rhs) {
        case (nil, nil): return true
        case let (a as Int32, b as Int32): return a == b
        case let (a as Int64, b as Int64): return a == b
        case let (a as Double, b as Double): return a == b
        case let (a as String, b as String): return a == b
        case let (a as Int256, b as Int256): return a == b
        case let (a as Buffer, b as Buffer): return a.makeData() == b.makeData()
        case let (a as TLRecord, b as TLRecord): return a === b
        case let (a as [Any], b as [Any]):
            return a.count == b.count && zip(a, b).allSatisfy { equal($0.0, $0.1) }
        default: return false
        }
    }

    private static func describe(_ value: Any?) -> String {
        guard let value = value else { return "absent" }
        if let integer = value as? Int32 { return String(integer) }
        if let integer = value as? Int64 { return String(integer) }
        if let number = value as? Double { return String(number) }
        if let text = value as? String {
            return String(text.prefix(160)).debugDescription + (text.count > 160 ? "…" : "")
        }
        if let record = value as? TLRecord { return record.typeName + "." + record.constructorName }
        if let bytes = value as? Buffer { return "\(bytes.size) bytes" }
        if let values = value as? [Any] {
            let names = values.prefix(5).map { describe($0) }.joined(separator: ", ")
            return "[\(names)\(values.count > 5 ? ", …" : "")]"
        }
        return String(describing: value)
    }
}
