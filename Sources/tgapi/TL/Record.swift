import Foundation

public protocol TLValue {
    static func fromTL(_ value: Any) -> Self?
    static func canReadTL(_ value: Any) -> Swift.Bool
    var tlValue: Any { get }
}

public extension TLValue {
    static func canReadTL(_ value: Any) -> Swift.Bool { fromTL(value) != nil }
}

extension Int32: TLValue {
    public static func fromTL(_ value: Any) -> Int32? { value as? Int32 }
    public var tlValue: Any { self }
}
extension Int64: TLValue {
    public static func fromTL(_ value: Any) -> Int64? { value as? Int64 }
    public var tlValue: Any { self }
}
extension Double: TLValue {
    public static func fromTL(_ value: Any) -> Double? { value as? Double }
    public var tlValue: Any { self }
}
extension String: TLValue {
    public static func fromTL(_ value: Any) -> String? { value as? String }
    public var tlValue: Any { self }
}
extension Int256: TLValue {
    public static func fromTL(_ value: Any) -> Int256? { value as? Int256 }
    public var tlValue: Any { self }
}
extension Buffer: TLValue {
    public static func fromTL(_ value: Any) -> Self? { value as? Self }
    public var tlValue: Any { self }
}
extension Optional: TLValue where Wrapped: TLValue {
    public static func canReadTL(_ value: Any) -> Swift.Bool { value is NSNull || Wrapped.canReadTL(value) }
    public static func fromTL(_ value: Any) -> Self? {
        if value is NSNull { return .some(nil) }
        return Wrapped.fromTL(value).map { .some($0) }
    }
    public var tlValue: Any { self.map { $0.tlValue } ?? NSNull() }
}
extension Array: TLValue where Element: TLValue {
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

public final class TLRecord: TLSerializable, TLValue {
    public let typeName: String
    public let constructorName: String
    let descriptor: TLConstructor?
    var fields = [String: Any]()
    var wireFields = [String: Range<Int>]()
    private(set) var changes = [TLFieldChange]()
    private var writtenFields = Set<String>()
    var wireSignature: Int32?
    public var record: TLRecord { self }
    public var tlValue: Any { self }
    public static func fromTL(_ value: Any) -> TLRecord? { value as? TLRecord }

    public init(type: String, constructor: String) {
        typeName = type
        constructorName = constructor
        descriptor = HostSchema.shared?.constructor(type: type, name: constructor)
    }
    init(function: String) {
        typeName = "!Function"
        constructorName = function
        descriptor = HostSchema.shared?.functions[function]
    }
    init(descriptor: TLConstructor, type: String) {
        self.descriptor = descriptor
        self.typeName = type
        self.constructorName = descriptor.name
    }
    public func value<T: TLValue>(_ name: String) -> T {
        // A view is only constructed after its required fields have been checked.
        T.fromTL(fields[name] ?? NSNull())!
    }
    public func set<T: TLValue>(_ name: String, _ value: T) {
        writtenFields.insert(name)
        let raw = value.tlValue
        fields[name] = raw is NSNull ? nil : raw
    }
    public func canRead<T: TLValue>(_ name: String, as type: T.Type) -> Swift.Bool {
        T.canReadTL(fields[name] ?? NSNull())
    }

    func recordChange(_ change: TLFieldChange) { changes.append(change) }

    // Rebuilt policy containers retain fields introduced by a newer host. A
    // field explicitly set to nil is an edit, not a missing field to restore.
    func retainUnwrittenFields(from original: TLRecord) {
        guard self !== original, typeName == original.typeName, constructorName == original.constructorName else { return }
        for (name, value) in original.fields where !writtenFields.contains(name) { fields[name] = value }
        wireSignature = original.wireSignature
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
