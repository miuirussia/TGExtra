import Foundation

// Reads stored host Swift fields without invoking computed properties.
enum HostValueReader {
    static func storedField(_ name: String, in value: Any) -> Any? {
        var mirror: Mirror? = Mirror(reflecting: unwrapOptional(value))
        while let current = mirror {
            if let field = current.children.first(where: { $0.label == name }) { return field.value }
            mirror = current.superclassMirror
        }
        return nil
    }

    static func rawNumber(_ value: Any) -> Int64? {
        let value = unwrapOptional(value)
        if let v = value as? Int64 { return v }
        if let v = value as? Int32 { return Int64(v) }
        if let v = value as? UInt32 { return Int64(v) }
        guard let raw = storedField("rawValue", in: value) else { return nil }
        if let v = raw as? Int64 { return v }
        if let v = raw as? Int32 { return Int64(v) }
        if let v = raw as? UInt32 { return Int64(v) }
        return nil
    }

    static func unwrapOptional(_ value: Any) -> Any {
        var current = value
        while true {
            let mirror = Mirror(reflecting: current)
            guard mirror.displayStyle == .optional,
                  let inner = mirror.children.first?.value else { return current }
            current = inner
        }
    }
}
