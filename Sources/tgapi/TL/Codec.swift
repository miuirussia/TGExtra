import Foundation

enum TLCodec {
    private static let vector: Int32 = 481674261
    static func descriptor(_ signature: Int32) -> TLConstructor? {
        HostSchema.shared?.constructors[signature]
    }

    static func parse(_ reader: BufferReader, descriptor: TLConstructor, depth: Int = 0) -> TLRecord? {
        guard depth < 128, let schema = HostSchema.shared,
              descriptor.typeIndex == 65535 || descriptor.typeIndex < schema.types.count else { return nil }
        return descriptor.fields.withUnsafeBufferPointer { fields in
            let wireStart = Int(reader.offset)
            var values = [Any?](repeating: nil, count: descriptor.fields.count)
            var wireFields = [String: Range<Int>]()
            var flags0: Int32?, flags1: Int32?
            for index in fields.indices {
                let flagsIndex = fields[index].flagsIndex
                if flagsIndex >= 0 {
                    let flagsValue = flagsIndex == 0 ? flags0 : (flagsIndex == 1 ? flags1 : values[flagsIndex] as? Int32)
                    guard let flags = flagsValue else { return nil }
                    if flags & (Int32(1) << fields[index].flagBit) == 0 { continue }
                }
                let field = fields[index]
                let start = Int(reader.offset)
                guard let value = read(field, reader: reader, depth: depth + 1) else { return nil }
                values[index] = value
                if index == 0 { flags0 = value as? Int32 }
                else if index == 1 { flags1 = value as? Int32 }
                if descriptor.tracksWireFields && (field.name == "flags" || field.name == "flags2" || field.name == "restrictionReason") {
                    wireFields[field.name] = start..<Int(reader.offset)
                }
            }
            let result = TLRecord(descriptor: descriptor, type: descriptor.typeIndex == 65535 ? "!Function" : schema.types[descriptor.typeIndex], values: values)
            result.wireFields = wireFields
            result.wireSource = reader.wireSource
            result.wireRange = wireStart..<Int(reader.offset)
            result.isDecoded = true
            reader.parsedRecords.append(result)
            return result
        }
    }

    static func scan(_ reader: BufferReader, descriptor: TLConstructor, users: inout [Api.User],
                     depth: Int = 0, harvestUser: Bool = false) -> Bool {
        guard depth < 128, let schema = HostSchema.shared, descriptor.typeIndex < schema.types.count else { return false }
        if !descriptor.canScan || ((harvestUser || depth == 0) && schema.types[descriptor.typeIndex] == "User") {
            guard let record = parse(reader, descriptor: descriptor, depth: depth) else { return false }
            if let user = Api.User(record) { users.append(user) }
            if depth == 0, let values = record["users"] as? [TLRecord] { users += values.compactMap(Api.User.init) }
            return true
        }
        var flags0: Int32?, flags1: Int32?
        var flags0Start = 0, flags1Start = 0
        var restricted: TLRecord?
        for (index, field) in descriptor.fields.enumerated() {
            if field.flagsIndex >= 0 {
                guard let flags = field.flagsIndex == 0 ? flags0 : flags1 else { return false }
                if flags & (Int32(1) << field.flagBit) == 0 { continue }
            }
            let start = Int(reader.offset)
            if descriptor.restrictionIndex == index {
                guard let value = read(field, reader: reader, depth: depth + 1) else { return false }
                let record = TLRecord(descriptor: descriptor, type: schema.types[descriptor.typeIndex])
                let flagsName = descriptor.fields[field.flagsIndex].name
                record[flagsName] = field.flagsIndex == 0 ? flags0 : flags1
                record[field.name] = value
                let flagStart = field.flagsIndex == 0 ? flags0Start : flags1Start
                record.wireFields[flagsName] = flagStart..<flagStart + 4
                record.wireFields[field.name] = start..<Int(reader.offset)
                restricted = record
            } else if field.kind == 0 {
                guard let value = reader.readInt32() else { return false }
                if index == 0 { flags0 = value; flags0Start = start }
                else if index == 1 { flags1 = value; flags1Start = start }
            } else if field.kind == 7 {
                if field.boxedVector, reader.readInt32() != vector { return false }
                guard let count = reader.readInt32(), count >= 0, Int(count) <= reader.remaining / 4 else { return false }
                for _ in 0..<count {
                    guard scanValue(field.elementKind, field: field, reader: reader, users: &users, depth: depth + 1,
                                    harvestUser: harvestUser || (depth == 0 && field.name == "users")) else { return false }
                }
            } else if !scanValue(field.kind, field: field, reader: reader, users: &users, depth: depth + 1,
                                 harvestUser: harvestUser) { return false }
        }
        if let record = restricted { reader.parsedRecords.append(record) }
        return true
    }

    private static func scanValue(_ kind: Int, field: TLField, reader: BufferReader, users: inout [Api.User],
                                  depth: Int, harvestUser: Bool) -> Bool {
        switch kind {
        case 0: return reader.skipValueBytes(4)
        case 1, 3: return reader.skipValueBytes(8)
        case 2: return reader.skipValueBytes(32)
        case 4, 5: return reader.skipTLBytes()
        case 6:
            let constructor: TLConstructor
            if field.bare {
                guard let value = HostSchema.shared?.bareConstructor(field) else { return false }
                constructor = value
            } else {
                guard let signature = reader.readInt32(), let value = descriptor(signature) else { return false }
                constructor = value
            }
            guard field.typeIndex == 65535 || constructor.typeIndex == field.typeIndex else { return false }
            return scan(reader, descriptor: constructor, users: &users, depth: depth, harvestUser: harvestUser)
        default: return false
        }
    }

    static func read(_ field: TLField, reader: BufferReader, depth: Int) -> Any? {
        if field.kind != 7 { return readValue(field.kind, field: field, reader: reader, depth: depth) }
        if field.boxedVector, reader.readInt32() != vector { return nil }
        guard let count = reader.readInt32(), count >= 0, Int(count) <= reader.remaining / 4 else { return nil }
        var values = [Any]()
        values.reserveCapacity(Int(count))
        for _ in 0..<count {
            guard let value = readValue(field.elementKind, field: field, reader: reader, depth: depth) else { return nil }
            values.append(value)
        }
        return values
    }

    private static func readValue(_ kind: Int, field: TLField, reader: BufferReader, depth: Int) -> Any? {
        switch kind {
        case 0: return reader.readInt32()
        case 1: return reader.readInt64()
        case 2: return parseInt256(reader)
        case 3: return reader.readDouble()
        case 4: return parseString(reader)
        case 5:
            reader.wireSource.canCopy = false
            return parseBytes(reader)
        case 6:
            let constructor: TLConstructor
            if field.bare {
                guard let value = HostSchema.shared?.bareConstructor(field) else { return nil }
                constructor = value
            } else {
                guard let value = reader.readInt32(), let valueDescriptor = descriptor(value) else { return nil }
                constructor = valueDescriptor
            }
            guard field.typeIndex == 65535 || constructor.typeIndex == field.typeIndex else { return nil }
            return parse(reader, descriptor: constructor, depth: depth)
        default: return nil
        }
    }

    static func serialize(_ record: TLRecord, into buffer: Buffer, boxed: Swift.Bool, depth: Int = 0) -> Swift.Bool {
        guard depth < 128, let descriptor = record.descriptor else { return false }
        if boxed { buffer.appendInt32(descriptor.signature) }
        if let source = record.wireSource, !source.isDirty, source.canCopy {
            source.bytes.withUnsafeBytes { bytes in
                if !record.wireRange.isEmpty {
                    buffer.appendBytes(bytes.baseAddress!.advanced(by: record.wireRange.lowerBound), length: UInt(record.wireRange.count))
                }
            }
            return true
        }
        let values = record.values
        let flags0 = values.first.flatMap { $0 as? Int32 }
        let flags1 = values.count > 1 ? values[1] as? Int32 : nil
        for (index, field) in descriptor.fields.enumerated() {
            if field.flagsIndex >= 0 {
                let flagsValue = field.flagsIndex == 0 ? flags0 : (field.flagsIndex == 1 ? flags1 : values[field.flagsIndex] as? Int32)
                guard let flags = flagsValue else { return false }
                if flags & (Int32(1) << field.flagBit) == 0 { continue }
            }
            guard let value = values[index] else { return false }
            if field.kind == 7 {
                guard let values = value as? [Any], values.count <= Int(Int32.max) else { return false }
                if field.boxedVector { buffer.appendInt32(vector) }
                buffer.appendInt32(Int32(values.count))
                for element in values {
                    guard write(element, kind: field.elementKind, field: field, into: buffer, depth: depth + 1) else { return false }
                }
            } else if !write(value, kind: field.kind, field: field, into: buffer, depth: depth + 1) { return false }
        }
        return true
    }

    private static func write(_ value: Any, kind: Int, field: TLField, into buffer: Buffer, depth: Int) -> Swift.Bool {
        switch kind {
        case 0:
            guard let value = value as? Int32 else { return false }
            buffer.appendInt32(value)
        case 1:
            guard let value = value as? Int64 else { return false }
            buffer.appendInt64(value)
        case 2:
            guard let value = value as? Int256 else { return false }
            serializeInt256(value, buffer: buffer, boxed: false)
        case 3:
            guard let value = value as? Double else { return false }
            buffer.appendDouble(value)
        case 4:
            guard let value = value as? String else { return false }
            serializeString(value, buffer: buffer, boxed: false)
        case 5:
            guard let value = value as? Buffer else { return false }
            serializeBytes(value, buffer: buffer, boxed: false)
        case 6:
            guard let value = value as? TLRecord, let descriptor = value.descriptor,
                  field.typeIndex == 65535 || descriptor.typeIndex == field.typeIndex else { return false }
            return serialize(value, into: buffer, boxed: !field.bare, depth: depth)
        default: return false
        }
        return true
    }
}

extension Api {
    static func isKnownConstructor(_ signature: Int32) -> Swift.Bool {
        switch signature {
        case -1471112230, 570911930, 571523412, 0x0929c32f, -1255641564: return true
        default: return TLCodec.descriptor(signature) != nil
        }
    }

    static func parse(_ reader: BufferReader, signature: Int32) -> Any? {
        switch signature {
        case -1471112230: return reader.readInt32()
        case 570911930: return reader.readInt64()
        case 571523412: return reader.readDouble()
        case 0x0929c32f: return parseInt256(reader)
        case -1255641564: return parseString(reader)
        default:
            guard let descriptor = TLCodec.descriptor(signature) else {
                telegramApiLog("Type constructor \(String(UInt32(bitPattern: signature), radix: 16)) not found in host schema")
                return nil
            }
            guard let record = TLCodec.parse(reader, descriptor: descriptor) else { return nil }
            return view(record)
        }
    }

    static func parseVector<T>(_ reader: BufferReader, elementSignature: Int32, elementType: T.Type) -> [T]? {
        guard let count = reader.readInt32(), count >= 0, Int(count) <= reader.remaining / 4 else { return nil }
        var values = [T]()
        values.reserveCapacity(Int(count))
        for _ in 0..<count {
            if elementType == Buffer.self {
                guard let value = parseBytes(reader) as? T else { return nil }
                values.append(value)
            } else {
                guard let signature = elementSignature == 0 ? reader.readInt32() : elementSignature,
                      let value = parse(reader, signature: signature) as? T else { return nil }
                values.append(value)
            }
        }
        return values
    }

    static func serializeObject(_ object: Any, buffer: Buffer, boxed: Swift.Bool) {
        guard let value = object as? TLSerializable else { buffer.isValid = false; return }
        value.serialize(buffer, boxed)
    }
}
