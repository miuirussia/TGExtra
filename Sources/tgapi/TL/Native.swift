import Foundation
import tgapiC

// Rules keep using TLDataPatch's named operations. This adapter reads existing
// host objects lazily and commits their edits after the complete decode succeeds.
final class NativeTLContext {
    private var records = [ObjectIdentifier: TLRecord]()
    private var wire = [ObjectIdentifier: (TLRecord, [String: Any])]()
    let reader = BufferReader(Buffer())

    init() { reader.nativeContext = self }

    func record(_ object: AnyObject) -> TLRecord? {
        let key = ObjectIdentifier(object)
        if let value = records[key] { return value }
        guard let native = TGExtraNativeObject(object: object),
              let descriptor = HostSchema.shared?.constructors[Int32(bitPattern: native.constructorId)],
              descriptor.typeIndex == Int(native.typeIndex), descriptor.fields.count == Int(native.fieldCount),
              let type = HostSchema.shared?.types[descriptor.typeIndex] else { return nil }
        let record = TLRecord(descriptor: descriptor, type: type)
        record.nativeObject = native
        record.nativeContext = self
        record.isDecoded = true
        records[key] = record
        return record
    }

    func value(_ record: TLRecord, index: Int) -> Any? {
        guard let descriptor = record.descriptor, let native = record.nativeObject else { return nil }
        let field = descriptor.fields[index]
        if field.kind <= 3 {
            guard let scalar = native.scalar(at: index) else { return nil }
            switch field.kind {
            case 0: return scalar.loadUnaligned(as: Int32.self)
            case 1: return scalar.loadUnaligned(as: Int64.self)
            case 2: return Int256(_0: scalar.loadUnaligned(as: Int64.self),
                _1: scalar.loadUnaligned(fromByteOffset: 8, as: Int64.self),
                _2: scalar.loadUnaligned(fromByteOffset: 16, as: Int64.self),
                _3: scalar.loadUnaligned(fromByteOffset: 24, as: Int64.self))
            case 3: return scalar.loadUnaligned(as: Double.self)
            default: return nil
            }
        }
        guard let value = native.value(at: index) else { return nil }
        switch field.kind {
        case 4: return value as? String
        case 5: return (value as? Data).map { Buffer(data: $0) }
        case 6: return self.record(value as AnyObject)
        case 7:
            if field.elementKind == 0 || field.elementKind == 1 {
                guard let bytes = value as? Data else { return nil }
                return bytes.withUnsafeBytes { raw -> Any in
                    if field.elementKind == 0 {
                        return stride(from: 0, to: bytes.count, by: 4).map { raw.loadUnaligned(fromByteOffset: $0, as: Int32.self) }
                    }
                    return stride(from: 0, to: bytes.count, by: 8).map { raw.loadUnaligned(fromByteOffset: $0, as: Int64.self) }
                }
            }
            guard let array = value as? [Any] else { return nil }
            if field.elementKind == 6 { return array.compactMap { self.record($0 as AnyObject) } }
            if field.elementKind == 5 { return array.compactMap { ($0 as? Data).map { Buffer(data: $0) } } }
            return array
        default: return nil
        }
    }

    func capture(_ record: TLRecord, field: String) {
        let key = ObjectIdentifier(record)
        var entry = wire[key] ?? (record, [:])
        entry.1[field] = record[field] ?? NSNull()
        wire[key] = entry
    }

    func materialize(_ record: TLRecord) -> AnyObject? {
        if let native = record.nativeObject { return native.object as AnyObject }
        let buffer = Buffer()
        record.serialize(buffer, true)
        guard let data = buffer.makeValidData() else { return nil }
        return TGExtraNativeCreate(data) as AnyObject?
    }

    private func nativeValue(_ value: Any?, field: TLField) -> Any? {
        guard let value = value, !(value is NSNull) else { return nil }
        if let record = value as? TLRecord { return materialize(record) ?? NSNull() }
        if let bytes = value as? Buffer { return bytes.makeData() }
        if let int = value as? Int256 {
            return [int._0, int._1, int._2, int._3].withUnsafeBytes { Data($0) }
        }
        if field.kind == 7 {
            if field.elementKind == 0, let ints = value as? [Int32] { return ints.withUnsafeBytes { Data($0) } }
            if field.elementKind == 1, let ints = value as? [Int64] { return ints.withUnsafeBytes { Data($0) } }
            if let values = value as? [Any] {
                return values.map { item -> Any in
                    if let record = item as? TLRecord { return materialize(record) ?? NSNull() }
                    if let bytes = item as? Buffer { return bytes.makeData() }
                    return item
                }
            }
        }
        return value
    }

    // Validate the complete write set before changing a native object.
    func commit(_ root: TLRecord?, allChanges: Bool) -> AnyObject? {
        let nativeRoot = root.flatMap(materialize)
        if root != nil && nativeRoot == nil { return nil }
        var writes = [(TGExtraNativeObject, Int, Any?)]()
        if allChanges {
            var edited = Array(records.values)
            if let root = root, !edited.contains(where: { $0 === root }) { edited.append(root) }
            for record in edited {
                guard let native = record.nativeObject, let descriptor = record.descriptor else { continue }
                for name in record.nativeEdits {
                    guard let index = descriptor.fieldIndices[name] else { return nil }
                    let value = nativeValue(record[name], field: descriptor.fields[index])
                    guard native.canSetValue(value, at: index) else { return nil }
                    writes.append((native, index, value))
                }
            }
        } else {
            for (record, fields) in wire.values {
                guard let native = record.nativeObject, let descriptor = record.descriptor else { return nil }
                for (name, raw) in fields {
                    guard let index = descriptor.fieldIndices[name] else { return nil }
                    let value = nativeValue(raw, field: descriptor.fields[index])
                    guard native.canSetValue(value, at: index) else { return nil }
                    writes.append((native, index, value))
                }
            }
        }
        for (native, index, value) in writes { guard native.setValue(value, at: index) else { return nil } }
        return nativeRoot
    }
}

extension TLParser {
    private static let nativeInstalled: Bool = {
        guard let schema = HostSchema.shared else { return false }
        let ids = schema.constructors.keys.map { UInt32(bitPattern: $0) }.sorted()
        var types = [UInt8](repeating: 0, count: schema.types.count)
        for (index, type) in schema.types.enumerated() where ["Message", "Chat", "User", "UserFull", "StoryItem"].contains(type) { types[index] = 1 }
        // Mark the transitive object types which can contain a patched object.
        // The native visitor never scans payload bytes or irrelevant leaf types.
        var changed = true
        while changed {
            changed = false
            for descriptor in schema.constructors.values where types[descriptor.typeIndex] == 0 {
                if descriptor.fields.contains(where: { field in
                    (field.kind == 6 || (field.kind == 7 && field.elementKind == 6)) &&
                    (field.typeIndex == 65535 || (field.typeIndex < types.count && types[field.typeIndex] != 0))
                }) { types[descriptor.typeIndex] = 2; changed = true }
            }
        }
        TGExtraNativeSetRules(MessagePatches.nativeRules(schema), UInt16(schema.types.firstIndex(of: "User")!))
        var counts = [UInt32](repeating: 0, count: schema.types.count)
        for descriptor in schema.constructors.values { counts[descriptor.typeIndex] += 1 }
        var offsets: [UInt32] = [0]
        for count in counts { offsets.append(offsets.last! + count) }
        var plans = [UInt32](repeating: 0, count: Int(offsets.last!) * 4)
        for descriptor in schema.constructors.values {
            let index = (Int(offsets[descriptor.typeIndex]) + descriptor.caseIndex) * 4
            plans[index] = UInt32(bitPattern: descriptor.signature)
            var children: UInt64 = 0
            for (fieldIndex, field) in descriptor.fields.enumerated() {
                if (field.kind == 6 || (field.kind == 7 && field.elementKind == 6)) &&
                    (field.typeIndex == 65535 || (field.typeIndex < types.count && types[field.typeIndex] != 0)) {
                    if fieldIndex < 64 { children |= UInt64(1) << fieldIndex } else { plans[index+3] = 1 }
                }
            }
            plans[index+1] = UInt32(truncatingIfNeeded: children)
            plans[index+2] = UInt32(truncatingIfNeeded: children >> 32)
        }
        offsets.withUnsafeBytes { offsets in plans.withUnsafeBytes { plans in
            TGExtraNativeSetTraversal(Data(offsets), Data(plans))
        } }
        return ids.withUnsafeBytes { ids in types.withUnsafeBytes { types in
            TGExtraNativeInstall(Data(ids), Data(types)) { root, packet, account, function, request in
                TLParser.patchNative(root, account: account, function: function, request: request) ?? root
            }
        } }
    }()

    @objc static func nativeTLAvailable() -> Bool { nativeInstalled || TGExtraNativeReady() }
}
