import Foundation

extension HostSchema {
    func request(_ data: Data) -> TLRecord? {
        let reader = BufferReader(Buffer(data: data))
        guard let signature = reader.readInt32(), let descriptor = functionsBySignature[signature],
              let record = TLCodec.parse(reader, descriptor: descriptor), reader.remaining == 0 else { return nil }
        return record
    }
}

extension TLRecord {
    func serializedData() -> Data? {
        let buffer = Buffer()
        serialize(buffer, true)
        return buffer.makeValidData()
    }
}

extension TLParser {
    static func request(_ data: NSData) -> TLRecord? { HostSchema.shared?.request(data as Data) }

    // Only construct the response forms whose semantics we understand. Field
    // order, IDs, optional presence and the method's result type come from host.
    static func emptyResponse(method: TLMethodID, constructor: String) -> NSData? {
        guard let schema = HostSchema.shared, let result = schema.functionResults[method.rawValue] else { return nil }
        if constructor == "vector" {
            guard result.kind == 7, result.boxedVector, result.elementKind == 0 else { return nil }
            let buffer = Buffer()
            buffer.appendInt32(481674261)
            buffer.appendInt32(0)
            return buffer.makeData() as NSData
        }
        guard result.kind == 6, result.typeIndex < schema.types.count else { return nil }
        let record = TLRecord(type: schema.types[result.typeIndex], constructor: constructor)
        guard let descriptor = record.descriptor else { return nil }
        for field in descriptor.fields where !field.optional {
            switch field.kind {
            case 0: record[field.name] = field.name == "date" ? Int32(Date().timeIntervalSince1970) : Int32(0)
            case 7: record[field.name] = [Any]()
            default: return nil
            }
        }
        return record.serializedData().map { $0 as NSData }
    }

    @objc static func isForwardRequest(_ payload: NSData) -> Bool {
        requestMethod(payload) == .messagesForward
    }

    @objc static func privacyReplacementRequest() -> NSData? {
        let record = TLRecord(function: .helpGetNearestDc)
        return record.serializedData().map { $0 as NSData }
    }
}
