import Foundation

func runCodecBenchmarks() {
    flags()
    let one = message(12345)
    let hundred = (1...100).map { message(Int32($0)) }
    let packet = Api.messages.Messages.messages(.init(messages: hundred, topics: [], chats: [], users: []))
    let timed = Api.messages.Messages.messages(.init(messages: (1...100).map { message(Int32($0), ttl: 86400) }, topics: [], chats: [], users: []))
    let single = serialized(one)
    let bytes = serialized(packet)
    let timedBytes = serialized(timed)
    for data in [single, bytes, timedBytes] {
        var hash: UInt64 = 14695981039346656037
        for byte in data as Data { hash = (hash ^ UInt64(byte)) &* 1099511628211 }
        print("FIXTURE bytes=\(data.length) hash=\(hash)")
    }
    func decode(_ data: NSData) -> Any {
        let r = BufferReader(Buffer(nsData: data))
        let value = Api.parse(r, signature: r.readInt32()!)!
        precondition(r.offset == UInt(data.length))
        return value
    }
    let decoded = decode(bytes)
    var checksum = 0
    func measure(_ name: String, iterations: Int = 100, _ operation: () -> Int) {
        for _ in 0..<5 { checksum &+= operation() }
        var samples = [Double]()
        for _ in 0..<5 {
            let start = DispatchTime.now().uptimeNanoseconds
            for _ in 0..<iterations { autoreleasepool { checksum &+= operation() } }
            samples.append(Double(DispatchTime.now().uptimeNanoseconds - start) / Double(iterations) / 1_000_000)
        }
        print("BENCH \(name) median_ms=\(samples.sorted()[2]) samples=\(samples)")
    }
    measure("parse/message", iterations: 1000) { (decode(single) as? Api.Message) != nil ? 1 : 0 }
    measure("parse/history100") { (decode(bytes) as? Api.messages.Messages) != nil ? 1 : 0 }
    measure("serialize/history100") { serialized(decoded).length }
    measure("patch/off/history100") { precondition(TLParser.stripAntiSelfDestruct(bytes, account: nil) == nil); return bytes.length }
    flags("disableForwardRestriction")
    measure("patch/forward/history100") { let out = TLParser.stripAntiSelfDestruct(bytes, account: nil)!; precondition(out == bytes); return out.length }
    flags("TGExtraAntiAutoDelete")
    measure("patch/ttl/history100") { let out = TLParser.stripAntiSelfDestruct(timedBytes, account: nil)!; precondition(out == bytes); return out.length }
    print("CHECKSUM \(checksum)")
}
