import Foundation
import tgapiC

struct TLField {
    let name: String
    let kind: Int
    let elementKind: Int
    let optional: Bool
    let boxedVector: Bool
    let bare: Bool
    let flagsIndex: Int
    let flagBit: Int
    let typeIndex: Int
    let constructorIndex: Int
}

struct TLConstructor {
    let name: String
    let signature: Int32
    let typeIndex: Int
    let caseIndex: Int
    let fields: [TLField]
}

final class HostSchema {
    static let shared: HostSchema? = TGExtraHostTLSchema().flatMap { HostSchema(image: $0) }
    let types: [String]
    let constructors: [Int32: TLConstructor]
    let functions: [String: TLConstructor]
    private let constructorsByName: [String: TLConstructor]
    private let bareConstructors: [Int: [TLConstructor]]

    init?(image: Data) {
        guard image.count >= 72, image.count <= 16 * 1024 * 1024 else { return nil }
        func u32(_ offset: Int) -> Int {
            image.withUnsafeBytes { Int(UInt32(littleEndian: $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self))) }
        }
        func u16(_ offset: Int) -> Int {
            image.withUnsafeBytes { Int(UInt16(littleEndian: $0.loadUnaligned(fromByteOffset: offset, as: UInt16.self))) }
        }
        guard u32(0) == 0x31534c54, u32(4) == 3, u32(16) == image.count else { return nil }
        let typeCount = u32(20), constructorCount = u32(24), functionCount = u32(28), fieldCount = u32(32)
        let poolOffset = u32(40), poolLength = u32(44), typesOffset = u32(48)
        let constructorsOffset = u32(56), fieldsOffset = u32(60), functionsOffset = u32(64)
        for (offset, count, size) in [(poolOffset, poolLength, 1), (typesOffset, typeCount, 12),
                                      (u32(52), u32(36), 4), (constructorsOffset, constructorCount, 28),
                                      (fieldsOffset, fieldCount, 20), (functionsOffset, functionCount, 28)] {
            guard offset >= 72, offset <= image.count, count <= (image.count - offset) / size else { return nil }
        }
        guard typeCount > 0, poolLength > 0, image[poolOffset + poolLength - 1] == 0 else { return nil }
        func string(_ offset: Int) -> String? {
            guard offset < poolLength else { return nil }
            let start = poolOffset + offset
            guard let end = image[start..<poolOffset + poolLength].firstIndex(of: 0) else { return nil }
            return String(data: image[start..<end], encoding: .utf8)
        }
        var types = [String]()
        for i in 0..<typeCount {
            guard let name = string(u32(typesOffset + i * 12)) else { return nil }
            types.append(name)
        }
        var fields = [TLField]()
        for i in 0..<fieldCount {
            let p = fieldsOffset + i * 20
            guard let name = string(u32(p)) else { return nil }
            let kind = Int(image[p + 4]), elementKind = Int(image[p + 5]), type = u16(p + 12)
            guard kind <= 7, elementKind <= 7, type < typeCount || type == 65535,
                  image[p + 6] <= 1, image[p + 7] <= 1, image[p + 8] <= 1, image[p + 10] < 32 else { return nil }
            fields.append(TLField(name: name.trimmingCharacters(in: CharacterSet(charactersIn: "`")),
                                  kind: kind, elementKind: elementKind, optional: image[p + 6] != 0,
                                  boxedVector: image[p + 7] != 0, bare: image[p + 8] != 0,
                                  flagsIndex: Int(Int8(bitPattern: image[p + 9])), flagBit: Int(image[p + 10]),
                                  typeIndex: type, constructorIndex: u16(p + 14)))
        }
        func fieldSlice(_ first: Int, _ count: Int) -> [TLField]? {
            guard first <= fields.count, count <= fields.count - first else { return nil }
            let result = Array(fields[first..<first + count])
            for field in result {
                guard field.flagsIndex >= -1, field.flagsIndex < count else { return nil }
                if field.flagsIndex >= 0 {
                    guard result[field.flagsIndex].kind == 0 else { return nil }
                }
            }
            return result
        }
        var constructors = [Int32: TLConstructor](), names = [String: TLConstructor](), bare = [Int: [TLConstructor]]()
        var previous: UInt32?
        for i in 0..<constructorCount {
            let p = constructorsOffset + i * 28
            let signature = UInt32(u32(p + 4)), type = u16(p + 8), caseIndex = u16(p + 10)
            guard let name = string(u32(p)), type < types.count,
                  let values = fieldSlice(u32(p + 12), u16(p + 16)),
                  previous == nil || signature > previous! else { return nil }
            previous = signature
            let constructor = TLConstructor(name: name, signature: Int32(bitPattern: signature), typeIndex: type,
                                            caseIndex: caseIndex, fields: values)
            let key = types[type] + "." + name
            guard names[key] == nil else { return nil }
            constructors[constructor.signature] = constructor
            names[key] = constructor
            bare[type, default: []].append(constructor)
        }
        for (type, values) in bare {
            let sorted = values.sorted { $0.caseIndex < $1.caseIndex }
            guard sorted.enumerated().allSatisfy({ $0.offset == $0.element.caseIndex }) else { return nil }
            bare[type] = sorted
        }
        for field in fields where field.bare {
            guard let values = bare[field.typeIndex], field.constructorIndex < values.count else { return nil }
        }
        var functions = [String: TLConstructor]()
        for i in 0..<functionCount {
            let p = functionsOffset + i * 28
            guard let name = string(u32(p)), functions[name] == nil,
                  let values = fieldSlice(u32(p + 8), u16(p + 12)), u32(p + 16) < fields.count else { return nil }
            functions[name] = TLConstructor(name: name, signature: Int32(bitPattern: UInt32(u32(p + 4))),
                                            typeIndex: 65535, caseIndex: 0, fields: values)
        }
        self.types = types
        self.constructors = constructors
        self.constructorsByName = names
        self.bareConstructors = bare
        self.functions = functions
    }

    func constructor(type: String, name: String) -> TLConstructor? { constructorsByName[type + "." + name] }
    func bareConstructor(_ field: TLField) -> TLConstructor? {
        guard let values = bareConstructors[field.typeIndex], field.constructorIndex < values.count else { return nil }
        return values[field.constructorIndex]
    }
}
