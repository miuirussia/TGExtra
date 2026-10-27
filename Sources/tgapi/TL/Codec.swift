import Foundation

// One table-driven codec for the host's original schema, including constructors
// that TGExtra has never named. There are no per-type wire parsers in the tweak.
enum TLCodec {
    private static let vector: Int32 = 481674261
    private static let legacy: [Int32: (String, String)] = [
        -727763770: ("Chat", "channel"), -1605464774: ("ChatFull", "channelFull"),
        1003796418: ("InputReplyTo", "inputReplyToMessage"), 462937446: ("MessageReplyHeader", "messageReplyHeader"),
        1020666860: ("UrlAuthResult", "urlAuthResultRequest"), 114026053: ("UserFull", "userFull"),
        876739868: ("wallet.NftItem", "nftItem"),
    ]

    static func descriptor(_ signature: Int32) -> TLConstructor? {
        guard let schema = HostSchema.shared else { return nil }
        return schema.constructors[signature] ?? legacy[signature].flatMap { schema.constructor(type: $0.0, name: $0.1) }
    }

    static func parse(_ reader: BufferReader, descriptor: TLConstructor, signature: Int32?, depth: Int = 0) -> TLRecord? {
        guard depth < 128, let schema = HostSchema.shared, descriptor.typeIndex < schema.types.count else { return nil }
        let result = TLRecord(descriptor: descriptor, type: schema.types[descriptor.typeIndex])
        if reader.preserveLegacyConstructorIds { result.wireSignature = signature }
        for field in descriptor.fields {
            if field.flagsIndex >= 0 {
                guard let flags = result.fields[descriptor.fields[field.flagsIndex].name] as? Int32 else { return nil }
                if flags & (Int32(1) << field.flagBit) == 0 { continue }
            }
            let start = Int(reader.offset)
            guard let value = read(field, reader: reader, depth: depth + 1) else { return nil }
            result.fields[field.name] = value
            result.wireFields[field.name] = start..<Int(reader.offset)
        }
        reader.parsedRecords.append(result)
        return result
    }

    private static func read(_ field: TLField, reader: BufferReader, depth: Int) -> Any? {
        if field.kind != 7 { return readValue(field.kind, field: field, reader: reader, depth: depth) }
        if field.boxedVector, reader.readInt32() != vector { return nil }
        guard let count = reader.readInt32(), count >= 0, Int(count) <= reader.remaining / 4 else { return nil }
        var values = [Any]()
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
        case 5: return parseBytes(reader)
        case 6:
            let constructor: TLConstructor
            let signature: Int32?
            if field.bare {
                guard let value = HostSchema.shared?.bareConstructor(field) else { return nil }
                constructor = value
                signature = nil
            } else {
                guard let value = reader.readInt32(), let valueDescriptor = descriptor(value) else { return nil }
                constructor = valueDescriptor
                signature = value
            }
            guard field.typeIndex == 65535 || constructor.typeIndex == field.typeIndex else { return nil }
            return parse(reader, descriptor: constructor, signature: signature, depth: depth)
        default: return nil
        }
    }

    static func serialize(_ record: TLRecord, into buffer: Buffer, boxed: Swift.Bool, depth: Int = 0) -> Swift.Bool {
        guard depth < 128, let descriptor = record.descriptor else { return false }
        if boxed { buffer.appendInt32(record.wireSignature ?? descriptor.signature) }
        for field in descriptor.fields {
            if field.flagsIndex >= 0 {
                guard let flags = record.fields[descriptor.fields[field.flagsIndex].name] as? Int32 else { return false }
                if flags & (Int32(1) << field.flagBit) == 0 { continue }
            }
            guard let value = record.fields[field.name] else { return false }
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
            guard let record = TLCodec.parse(reader, descriptor: descriptor, signature: signature) else { return nil }
            return view(record)
        }
    }

    static func parseVector<T>(_ reader: BufferReader, elementSignature: Int32, elementType: T.Type) -> [T]? {
        guard let count = reader.readInt32(), count >= 0, Int(count) <= reader.remaining / 4 else { return nil }
        var values = [T]()
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
