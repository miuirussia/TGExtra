import Foundation

struct Int128 {
    var _0: Int64
    var _1: Int64

    init(_0: Int64, _1: Int64) {
        self._0 = _0
        self._1 = _1
    }
}

struct Int256: Equatable, CustomStringConvertible {
    var _0: Int64
    var _1: Int64
    var _2: Int64
    var _3: Int64

    init(_0: Int64, _1: Int64, _2: Int64, _3: Int64) {
        self._0 = _0
        self._1 = _1
        self._2 = _2
        self._3 = _3
    }

    var description: String {
        var data = Data(count: 32)
        data.withUnsafeMutableBytes { buffer in
            if let baseAddress = buffer.baseAddress {
                let int64Buffer = baseAddress.assumingMemoryBound(to: Int64.self)
                int64Buffer[0] = self._0
                int64Buffer[1] = self._1
                int64Buffer[2] = self._2
                int64Buffer[3] = self._3
            }
        }

        let hexString = NSMutableString()
        data.withUnsafeBytes { rawBytes -> Void in
            let bytes = rawBytes.baseAddress!.assumingMemoryBound(to: UInt8.self)
            for i in 0 ..< data.count {
                hexString.appendFormat("%02x", UInt(bytes.advanced(by: i).pointee))
            }
        }

        return hexString as String
    }
}

func serializeInt32(_ value: Int32, buffer: Buffer, boxed: Bool) {
    if boxed {
        buffer.appendInt32(-1471112230)
    }
    buffer.appendInt32(value)
}

func serializeInt64(_ value: Int64, buffer: Buffer, boxed: Bool) {
    if boxed {
        buffer.appendInt32(570911930)
    }
    buffer.appendInt64(value)
}

func serializeDouble(_ value: Double, buffer: Buffer, boxed: Bool) {
    if boxed {
        buffer.appendInt32(571523412)
    }
    buffer.appendDouble(value)
}

func serializeString(_ value: String, buffer: Buffer, boxed: Bool) {
    let stringBuffer = Buffer()
    let data = value.data(using: .utf8, allowLossyConversion: true) ?? Data()
    data.withUnsafeBytes { bytes in
        stringBuffer.appendBytes(bytes.baseAddress!, length: UInt(bytes.count))
    }
    serializeBytes(stringBuffer, buffer: buffer, boxed: boxed)
}

func serializeBytes(_ value: Buffer, buffer: Buffer, boxed: Bool) {
        if boxed {
            buffer.appendInt32(-1255641564)
        }

        var length: Int32 = Int32(value.size)
        var padding: Int32 = 0
        if (length >= 254)
        {
            var tmp: UInt8 = 254
            buffer.appendBytes(&tmp, length: 1)
            buffer.appendBytes(&length, length: 3)
            padding = (((length % 4) == 0 ? length : (length + 4 - (length % 4)))) - length;
        }
        else
        {
            buffer.appendBytes(&length, length: 1)

            let e1 = (((length + 1) % 4) == 0 ? (length + 1) : ((length + 1) + 4 - ((length + 1) % 4)))
            padding = (e1) - (length + 1)
        }

        if value.size != 0 {
            buffer.appendBytes(value.data!, length: UInt(length))
        }

        var i: Int32 = 0
        var tmp: UInt8 = 0
        while i < padding {
            buffer.appendBytes(&tmp, length: 1)
            i += 1
        }
}

func serializeInt128(_ value: Int128, buffer: Buffer, boxed: Bool) {
    if boxed {
        buffer.appendInt32(1270167083)
    }

    buffer.appendInt64(value._0)
    buffer.appendInt64(value._1)
}

func serializeInt256(_ value: Int256, buffer: Buffer, boxed: Bool) {
    if boxed {
        buffer.appendInt32(153731887)
    }

    buffer.appendInt64(value._0)
    buffer.appendInt64(value._1)
    buffer.appendInt64(value._2)
    buffer.appendInt64(value._3)
}

func parseInt128(_ reader: BufferReader) -> Int128? {
    let _0 = reader.readInt64()
    let _1 = reader.readInt64()
    if _0 != nil && _1 != nil {
        return Int128(_0: _0!, _1: _1!)
    }
    return nil
}

func parseInt256(_ reader: BufferReader) -> Int256? {
    let _0 = reader.readInt64()
    let _1 = reader.readInt64()
    let _2 = reader.readInt64()
    let _3 = reader.readInt64()
    if _0 != nil && _1 != nil && _2 != nil && _3 != nil {
        return Int256(_0: _0!, _1: _1!, _2: _2!, _3: _3!)
    }
    return nil
}

private func roundUp(_ numToRound: Int, multiple: Int) -> Int
{
    if multiple == 0 {
        return numToRound
    }

    let remainder = numToRound % multiple
    if remainder == 0 {
        return numToRound;
    }

    return numToRound + multiple - remainder
}

func parseBytes(_ reader: BufferReader) -> Buffer? {
    if let tmp = reader.readBytesAsInt32(1) {
        var paddingBytes: Int = 0
        var length: Int = 0
        if tmp == 254 {
            if let len = reader.readBytesAsInt32(3) {
                length = Int(len)
                paddingBytes = roundUp(length, multiple: 4) - length
            }
            else {
                return nil
            }
        }
        else {
            length = Int(tmp)
            paddingBytes = roundUp(length + 1, multiple: 4) - (length + 1)
        }

        let buffer = reader.readBuffer(length)
        if tmp == 255 || paddingBytes > reader.remaining { reader.wireSource.canCopy = false }
        reader.skip(paddingBytes)
        return buffer
    }
    return nil
}

func parseString(_ reader: BufferReader) -> String? {
    if let buffer = parseBytes(reader) {
        if let value = String(data: buffer.makeData(), encoding: .utf8) { return value }
        reader.wireSource.canCopy = false
        return ""
    }
    return nil
}

class Buffer: CustomStringConvertible {
    var isValid = true
    var data: UnsafeMutableRawPointer?
    var _size: UInt = 0
    private var capacity: UInt = 0
    private let freeWhenDone: Bool

    var size: Int {
        return Int(self._size)
    }

    deinit {
        if self.freeWhenDone {
            if let data = self.data {
                free(data)
            }
        }
    }

    init(memory: UnsafeMutableRawPointer?, size: Int, capacity: Int, freeWhenDone: Bool) {
        self.data = memory
        self._size = UInt(size)
        self.capacity = UInt(capacity)
        self.freeWhenDone = freeWhenDone
    }

    init() {
        self.data = nil
        self._size = 0
        self.capacity = 0
        self.freeWhenDone = true
    }

    convenience init(data: Data?) {
        self.init()

        if let data = data {
            data.withUnsafeBytes { bytes in
                self.appendBytes(bytes.baseAddress!, length: UInt(bytes.count))
            }
        }
    }

    func makeData() -> Data {
        guard isValid else { return Data() }
        return self.withUnsafeMutablePointer { pointer, size -> Data in
            if let pointer = pointer {
                return Data(bytes: pointer.assumingMemoryBound(to: UInt8.self), count: Int(size))
            } else {
                return Data()
            }
        }
    }

    func makeValidData() -> Data? { isValid ? makeData() : nil }

    var description: String {
        get {
            var string = ""
            if let data = self.data {
                var i: UInt = 0
                let bytes = data.assumingMemoryBound(to: UInt8.self)
                while i < _size && i < 8 {
                    string += String(format: "%02x", Int(bytes.advanced(by: Int(i)).pointee))
                    i += 1
                }
                if i < _size {
                    string += "...\(_size)b"
                }
            } else {
                string += "<null>"
            }
            return string
        }
    }

    func appendBytes(_ bytes: UnsafeRawPointer, length: UInt) {
        if self.capacity < self._size + length {
            self.capacity = self._size + length + 128
            if self.data == nil {
                self.data = malloc(Int(self.capacity))!
            }
            else {
                self.data = realloc(self.data, Int(self.capacity))!
            }
        }

        memcpy(self.data?.advanced(by: Int(self._size)), bytes, Int(length))
        self._size += length
    }

    func appendBuffer(_ buffer: Buffer) {
        if buffer === self {
            let bytes = buffer.makeData()
            bytes.withUnsafeBytes { raw in
                if let base = raw.baseAddress { appendBytes(base, length: UInt(raw.count)) }
            }
            return
        }
        if buffer._size > 0, let bytes = buffer.data {
            appendBytes(bytes, length: buffer._size)
        }
    }

    func appendInt32(_ value: Int32) {
        var v = value
        self.appendBytes(&v, length: 4)
    }

    func appendInt64(_ value: Int64) {
        var v = value
        self.appendBytes(&v, length: 8)
    }

    func appendDouble(_ value: Double) {
        var v = value
        self.appendBytes(&v, length: 8)
    }

    func withUnsafeMutablePointer<R>(_ f: (UnsafeMutableRawPointer?, UInt) -> R) -> R {
        return f(self.data, self._size)
    }
}

class BufferReader {
    private let buffer: Buffer
    lazy var wireSource = TLWireSource(buffer)
    private(set) var offset: UInt = 0
    var remaining: Int { buffer.size - Int(offset) }
    var parsedRecords = [TLRecord]()
    weak var nativeContext: NativeTLContext?
    var changes: [TLFieldChange] { parsedRecords.flatMap(\.changes) }
    private var pendingWireEdits = [Range<Int>: TLWireEdit]()
    var wireEdits: [TLWireEdit] { pendingWireEdits.values.sorted { $0.range.lowerBound < $1.range.lowerBound } }

    init(_ buffer: Buffer) {
        self.buffer = buffer
    }

    func reset() {
        self.offset = 0
        self.parsedRecords.removeAll()
        self.pendingWireEdits.removeAll()
    }

    func skip(_ count: Int) {
        self.offset = min(self.buffer._size, self.offset + UInt(count))
    }

    func skipValueBytes(_ count: Int) -> Bool {
        guard count >= 0, count <= remaining else { return false }
        offset += UInt(count)
        return true
    }

    func skipTLBytes() -> Bool {
        guard let first = readBytesAsInt32(1) else { return false }
        let header = first == 254 ? 4 : 1
        let length: Int
        if first == 254 {
            guard let value = readBytesAsInt32(3) else { return false }
            length = Int(value)
        } else { length = Int(first) }
        let padding = (4 - (header + length) % 4) % 4
        return skipValueBytes(length + padding)
    }

    func readInt32() -> Int32? {
        if self.offset + 4 <= self.buffer._size {
            let value: Int32 = buffer.data!.advanced(by: Int(self.offset)).assumingMemoryBound(to: Int32.self).pointee
            self.offset += 4
            return value
        }
        return nil
    }

    func readInt64() -> Int64? {
        if self.offset + 8 <= self.buffer._size {
            let value: Int64 = buffer.data!.advanced(by: Int(self.offset)).assumingMemoryBound(to: Int64.self).pointee
            self.offset += 8
            return value
        }
        return nil
    }

    func readDouble() -> Double? {
        if self.offset + 8 <= self.buffer._size {
            let value: Double = buffer.data!.advanced(by: Int(self.offset)).assumingMemoryBound(to: Double.self).pointee
            self.offset += 8
            return value
        }
        return nil
    }

    func readBytesAsInt32(_ count: Int) -> Int32? {
        if count == 0 {
            return 0
        }
        guard count > 0, count <= 4, self.offset + UInt(count) <= self.buffer._size else {
            return nil
        }
        guard let bufferData = self.buffer.data else {
            return nil
        }
        var value: Int32 = 0
        memcpy(&value, bufferData.advanced(by: Int(self.offset)), count)
        self.offset += UInt(count)
        return value
    }

    func readBuffer(_ count: Int) -> Buffer? {
        if count >= 0 && self.offset + UInt(count) <= self.buffer._size {
            let buffer = Buffer()
            buffer.appendBytes((self.buffer.data?.advanced(by: Int(self.offset)))!, length: UInt(count))
            self.offset += UInt(count)
            return buffer
        }
        return nil
    }

    func withReadBufferNoCopy<T>(_ count: Int, _ f: (Buffer) -> T) -> T? {
        if count >= 0 && self.offset + UInt(count) <= self.buffer._size {
            return f(Buffer(memory: self.buffer.data!.advanced(by: Int(self.offset)), size: count, capacity: count, freeWhenDone: false))
        }
        return nil
    }
}

struct TLWireEdit {
    let path: String
    let range: Range<Int>
    let replacement: Data
}

extension BufferReader {
    func replaceFlags(of record: TLRecord, field: String) {
        if let native = nativeContext { native.capture(record, field: field); return }
        guard let range = record.wireFields[field], range.count == 4,
              let flags = record[field] as? Int32 else { return }
        var encoded = flags.littleEndian
        let replacement = withUnsafeBytes(of: &encoded) { Data($0) }
        if let bytes = buffer.data, range.lowerBound >= 0, range.upperBound <= buffer.size,
           Data(bytes: bytes.advanced(by: range.lowerBound), count: range.count) == replacement {
            pendingWireEdits.removeValue(forKey: range)
            return
        }
        pendingWireEdits[range] = TLWireEdit(path: record.typeName + "." + record.constructorName + "." + field,
                                            range: range, replacement: replacement)
    }

    func removeFieldBytes(of record: TLRecord, field: String) {
        if let native = nativeContext { native.capture(record, field: field); return }
        guard let range = record.wireFields[field], !range.isEmpty else { return }
        pendingWireEdits[range] = TLWireEdit(path: record.typeName + "." + record.constructorName + "." + field,
                                            range: range, replacement: Data())
    }

    func dataApplyingPatches(in range: Range<Int>? = nil,
                            replacing replacements: [(Range<Int>, Data)] = []) -> NSData? {
        let range = range ?? 0..<Int(buffer.size)
        let edits = (wireEdits.map { ($0.range, $0.replacement) }.filter { edit in
            !replacements.contains { $0.0.overlaps(edit.0) }
        } + replacements).filter { range.lowerBound <= $0.0.lowerBound && $0.0.upperBound <= range.upperBound }
        guard !edits.isEmpty else { return nil }
        let original = buffer.makeData().subdata(in: range)
        var output = original
        for (span, replacement) in edits.sorted(by: { $0.0.lowerBound > $1.0.lowerBound }) {
            output.replaceSubrange((span.lowerBound - range.lowerBound)..<(span.upperBound - range.lowerBound), with: replacement)
        }
        return output == original ? nil : output as NSData
    }
}

extension Buffer {
    convenience init(nsData: NSData) {
        self.init()
        self.appendBytes(nsData.bytes, length: UInt(nsData.length))
    }
}
