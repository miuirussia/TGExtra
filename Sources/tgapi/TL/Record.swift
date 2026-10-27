import Foundation

// View compatibility depends on schema metadata, not individual packet values.
public struct TLShape {
    let kind: Int
    var elementKind = 0
    var objectType: String? = nil
    var optional = false

    func matches(_ field: TLField, types: [String]) -> Swift.Bool {
        guard kind == field.kind, optional || !field.optional else { return false }
        if kind == 7 && elementKind != field.elementKind { return false }
        if let type = objectType {
            guard field.typeIndex < types.count, types[field.typeIndex] == type else { return false }
        }
        return true
    }
}

public protocol TLValue {
    static var tlShape: TLShape { get }
    static func fromTL(_ value: Any) -> Self?
    static func canReadTL(_ value: Any) -> Swift.Bool
    var tlValue: Any { get }
}

public extension TLValue {
    static func canReadTL(_ value: Any) -> Swift.Bool { fromTL(value) != nil }
}

extension Int32: TLValue {
    public static var tlShape: TLShape { TLShape(kind: 0) }
    public static func fromTL(_ value: Any) -> Int32? { value as? Int32 }
    public var tlValue: Any { self }
}
extension Int64: TLValue {
    public static var tlShape: TLShape { TLShape(kind: 1) }
    public static func fromTL(_ value: Any) -> Int64? { value as? Int64 }
    public var tlValue: Any { self }
}
extension Double: TLValue {
    public static var tlShape: TLShape { TLShape(kind: 3) }
    public static func fromTL(_ value: Any) -> Double? { value as? Double }
    public var tlValue: Any { self }
}
extension String: TLValue {
    public static var tlShape: TLShape { TLShape(kind: 4) }
    public static func fromTL(_ value: Any) -> String? { value as? String }
    public var tlValue: Any { self }
}
extension Int256: TLValue {
    public static var tlShape: TLShape { TLShape(kind: 2) }
    public static func fromTL(_ value: Any) -> Int256? { value as? Int256 }
    public var tlValue: Any { self }
}
extension Buffer: TLValue {
    public static var tlShape: TLShape { TLShape(kind: 5) }
    public static func fromTL(_ value: Any) -> Self? { value as? Self }
    public var tlValue: Any { self }
}
extension Optional: TLValue where Wrapped: TLValue {
    public static var tlShape: TLShape {
        var shape = Wrapped.tlShape
        shape.optional = true
        return shape
    }
    public static func canReadTL(_ value: Any) -> Swift.Bool { value is NSNull || Wrapped.canReadTL(value) }
    public static func fromTL(_ value: Any) -> Self? {
        if value is NSNull { return .some(nil) }
        return Wrapped.fromTL(value).map { .some($0) }
    }
    public var tlValue: Any { self.map { $0.tlValue } ?? NSNull() }
}
extension Array: TLValue where Element: TLValue {
    public static var tlShape: TLShape {
        TLShape(kind: 7, elementKind: Element.tlShape.kind, objectType: Element.tlShape.objectType)
    }
    public static func canReadTL(_ value: Any) -> Swift.Bool {
        guard let values = value as? [Any] else { return false }
        return values.allSatisfy(Element.canReadTL)
    }
    public static func fromTL(_ value: Any) -> Self? {
        guard let values = value as? [Any] else { return nil }
        var result = [Element]()
        for value in values {
            guard let element = Element.fromTL(value) else { return nil }
            result.append(element)
        }
        return result
    }
    public var tlValue: Any { map { $0.tlValue } }
}

public protocol TLSerializable: TypeConstructorDescription {
    var record: TLRecord { get }
}

public extension TLSerializable {
    func serialize(_ buffer: Buffer, _ boxed: Swift.Bool) {
        if !TLCodec.serialize(record, into: buffer, boxed: boxed) { buffer.isValid = false }
    }
    func descriptionFields() -> (String, [(String, ConstructorParameterDescription)]) {
        (record.constructorName, record.fields.sorted { $0.key < $1.key }.map {
            ($0.key, ConstructorParameterDescription(Api.exposedValue($0.value)))
        })
    }
}

public protocol TLObjectView: TLSerializable, TLValue {
    static var tlTypeName: String { get }
    init?(_ record: TLRecord)
}

public extension TLObjectView {
    static var tlShape: TLShape { TLShape(kind: 6, objectType: tlTypeName) }
    static func canReadTL(_ value: Any) -> Swift.Bool {
        (value as? TLRecord)?.typeName == tlTypeName
    }
    static func fromTL(_ value: Any) -> Self? {
        guard let record = value as? TLRecord else { return nil }
        return Self(record)
    }
    var tlValue: Any { record }
}

public class TLPayload: TLSerializable {
    public let record: TLRecord
    public init(record: TLRecord) { self.record = record }
    public init(type: String, constructor: String) {
        self.record = TLRecord(type: type, constructor: constructor)
    }
}

// Shared by records decoded from one immutable packet. Any object edit
// invalidates raw serialization for the whole packet, including ancestor views.
final class TLWireSource {
    let bytes: Data
    var isDirty = false
    var canCopy = true
    init(_ buffer: Buffer) { bytes = buffer.makeData() }
}

public final class TLRecord: TLSerializable, TLValue {
    public let typeName: String
    public let constructorName: String
    private(set) var descriptor: TLConstructor?
    var wireSource: TLWireSource?
    var wireRange = 0..<0
    var isDecoded = false
    var hasCompatibleView: Swift.Bool { isDecoded && descriptor?.supportsView == true }
    // The schema owns name lookup; the codec reads and writes by field index.
    private(set) var values: [Any?]
    var fields: [String: Any] {
        get {
            guard let descriptor = descriptor else { return [:] }
            return Dictionary(uniqueKeysWithValues: descriptor.fields.enumerated().compactMap { index, field in
                values[index].map { (field.name, $0) }
            })
        }
        set {
            isDecoded = false
            wireSource?.isDirty = true
            guard let descriptor = descriptor else { return }
            for (index, field) in descriptor.fields.enumerated() { values[index] = newValue[field.name] }
        }
    }
    subscript(_ name: String) -> Any? {
        get {
            guard let index = descriptor?.fieldIndices[name] else { return nil }
            return values[index]
        }
        set {
            guard let index = descriptor?.fieldIndices[name] else { return }
            values[index] = newValue
            isDecoded = false
            wireSource?.isDirty = true
        }
    }
    var wireFields = [String: Range<Int>]()
    private(set) var changes = [TLFieldChange]()
    private var writtenFields = Set<String>()
    public static var tlShape: TLShape { TLShape(kind: 6) }
    public var record: TLRecord { self }
    public var tlValue: Any { self }
    public static func fromTL(_ value: Any) -> TLRecord? { value as? TLRecord }

    public init(type: String, constructor: String) {
        typeName = type
        constructorName = constructor
        descriptor = HostSchema.shared?.constructor(type: type, name: constructor)
        values = Array(repeating: nil, count: descriptor?.fields.count ?? 0)
    }
    init(function: String) {
        typeName = "!Function"
        constructorName = function
        descriptor = HostSchema.shared?.functions[function]
        values = Array(repeating: nil, count: descriptor?.fields.count ?? 0)
    }
    init(descriptor: TLConstructor, type: String, values: [Any?]? = nil) {
        self.descriptor = descriptor
        self.typeName = type
        self.constructorName = descriptor.name
        self.values = values ?? Array(repeating: nil, count: descriptor.fields.count)
    }
    public func value<T: TLValue>(_ name: String) -> T {
        // A view is only constructed after its required fields have been checked.
        T.fromTL(self[name] ?? NSNull())!
    }
    public func set<T: TLValue>(_ name: String, _ value: T) {
        writtenFields.insert(name)
        let raw = value.tlValue
        self[name] = raw is NSNull ? nil : raw
    }
    public func canRead<T: TLValue>(_ name: String, as type: T.Type) -> Swift.Bool {
        T.canReadTL(self[name] ?? NSNull())
    }

    func recordChange(_ change: TLFieldChange) { changes.append(change) }

    // Rebuilt policy containers retain fields introduced by a newer host. A
    // field explicitly set to nil is an edit, not a missing field to restore.
    func retainUnwrittenFields(from original: TLRecord) {
        guard self !== original, typeName == original.typeName, constructorName == original.constructorName else { return }
        guard let descriptor = original.descriptor else { return }
        wireSource?.isDirty = true
        isDecoded = false
        if self.descriptor !== descriptor {
            let ownFields = fields
            self.descriptor = descriptor
            values = descriptor.fields.enumerated().map { index, field in
                writtenFields.contains(field.name) ? ownFields[field.name] : original.values[index]
            }
        } else {
            for (index, field) in descriptor.fields.enumerated() where !writtenFields.contains(field.name) {
                values[index] = original.values[index]
            }
        }
    }
}

extension Api {
    static func exposedValue(_ value: Any) -> Any {
        if let record = value as? TLRecord { return view(record) }
        if let values = value as? [Any] { return values.map(exposedValue) }
        return value
    }
    static func record(_ value: Any) -> TLRecord? { (value as? TLSerializable)?.record }
}
