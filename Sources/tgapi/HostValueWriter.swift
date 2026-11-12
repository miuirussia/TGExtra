import Foundation
import ObjectiveC

typealias HostVideoSend = (String, Bool, Int32?, @escaping () -> Void) -> Bool

// Swift Mirror's runtime supplies offsets and exact field types for the loaded
// client. No offsets or nominal host layouts are copied from a reference build.
private struct HostFieldMetadata {
    var name: UnsafePointer<CChar>?
    var freeName: (@convention(c) (UnsafePointer<CChar>?) -> Void)?
    var isStrong = false
    var isVar = false
}
@_silgen_name("swift_reflectionMirror_recursiveCount")
private func hostFieldCount(_ type: Any.Type) -> Int
@_silgen_name("swift_reflectionMirror_recursiveChildOffset")
private func hostFieldOffset(_ type: Any.Type, _ index: Int) -> Int
@_silgen_name("swift_reflectionMirror_recursiveChildMetadata")
private func hostFieldType(_ type: Any.Type, _ index: Int, _ metadata: UnsafeMutablePointer<HostFieldMetadata>) -> Any.Type

enum HostValueWriter {
    static func access<R>(_ name: String, in value: Any, type expected: Any.Type,
                          size: Int, alignment: Int, body: (UnsafeMutableRawPointer) -> R) -> (Any, R)? {
        let style = Mirror(reflecting: value).displayStyle
        guard style == .class || style == .struct else { return nil }
        func open<T>(_ input: T) -> (Any, R)? {
            let type = Swift.type(of: input)
            let count = hostFieldCount(type)
            guard (0...512).contains(count) else { return nil }
            for index in 0..<count {
                var metadata = HostFieldMetadata()
                let fieldType = hostFieldType(type, index, &metadata)
                let matches = metadata.name.map { String(cString: $0) == name } ?? false
                metadata.freeName?(metadata.name)
                guard matches, fieldType == expected else { continue }
                let offset = hostFieldOffset(type, index)
                func apply(_ base: UnsafeMutableRawPointer, limit: Int) -> R? {
                    guard offset >= 0, offset <= limit, size <= limit - offset,
                          Int(bitPattern: base.advanced(by: offset)) % alignment == 0 else { return nil }
                    return body(base.advanced(by: offset))
                }
                var copy = input
                if style == .class {
                    let object = input as AnyObject
                    guard let cls = object_getClass(object),
                          let result = apply(Unmanaged.passUnretained(object).toOpaque(), limit: class_getInstanceSize(cls)) else { return nil }
                    return (copy, result)
                }
                guard let result = withUnsafeMutablePointer(to: &copy, { apply(UnsafeMutableRawPointer($0), limit: MemoryLayout<T>.size) }) else { return nil }
                return (copy, result)
            }
            return nil
        }
        return _openExistential(value, do: open)
    }

    static func replacing(_ name: String, in value: Any, with replacement: Any) -> Any? {
        func assign<T>(_ item: T) -> Any? {
            access(name, in: value, type: T.self, size: MemoryLayout<T>.size, alignment: MemoryLayout<T>.alignment) {
                $0.assumingMemoryBound(to: T.self).pointee = item
            }?.0
        }
        return _openExistential(replacement, do: assign)
    }

    static func optional(_ value: Any) -> Any {
        func wrap<T>(_ value: T) -> Any { Optional.some(value) as Any }
        return _openExistential(value, do: wrap)
    }
}

protocol HostStringDictionary {
    var hostEntries: [String: Any] { get }
    func removing(_ keys: Set<String>) -> Any
    func restoring(_ snapshot: Any, keys: Set<String>) -> Any
}

extension Dictionary: HostStringDictionary where Key == String {
    var hostEntries: [String: Any] { mapValues { $0 as Any } }
    func removing(_ keys: Set<String>) -> Any { filter { !keys.contains($0.key) } }
    func restoring(_ snapshot: Any, keys: Set<String>) -> Any {
        guard let snapshot = snapshot as? Self else { return self }
        var result = self
        for key in keys where result[key] == nil { result[key] = snapshot[key] }
        return result
    }
}
