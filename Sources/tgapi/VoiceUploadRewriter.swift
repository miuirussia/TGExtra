import Foundation

extension TLParser {
    static func packWaveform(_ bars: Data) -> Data {
        let count = bars.count
        guard count > 0 else { return Data() }
        let byteLength = (count * 5 + 7) / 8
        var out = Data(count: byteLength + 4)
        out.withUnsafeMutableBytes { rawOut in
            guard let base = rawOut.baseAddress else { return }
            for i in 0 ..< count {
                let value = UInt32(bars[bars.startIndex + i] & 0x1f)
                let bitOffset = i * 5
                let pointer = base.advanced(by: bitOffset / 8)
                var current: UInt32 = 0
                memcpy(&current, pointer, 4)
                current |= value << UInt32(bitOffset % 8)
                memcpy(pointer, &current, 4)
            }
        }
        return out.prefix(byteLength)
    }

    static func voiceAttribute(_ upload: VoiceUpload) -> Api.DocumentAttribute {
        var flags: Int32 = 1 << 10          // voice
        var waveform: Buffer?
        if let bars = upload.waveform, !bars.isEmpty {
            flags |= 1 << 2                 // waveform present
            waveform = Buffer(data: packWaveform(bars))
        }
        return Api.DocumentAttribute.documentAttributeAudio(
            Api.DocumentAttribute.Cons_documentAttributeAudio(
                flags: flags, duration: upload.duration,
                title: nil, performer: nil, waveform: waveform))
    }

    static func voiceMedia(from media: Api.InputMedia) -> Api.InputMedia? {
        guard case let .inputMediaUploadedDocument(data) = media else { return nil }

        var fileName: String?
        for attribute in data.attributes {
            switch attribute {
            case let .documentAttributeFilename(nameData):
                fileName = nameData.fileName
            default:
                break
            }
        }

        var newAttributes: [Api.DocumentAttribute]?

        if let name = fileName, let upload = voiceUpload(forFileName: name) {
            diag("v2v wire: \(name) -> voice, \(upload.duration)s")
            newAttributes = [voiceAttribute(upload)]
        }

        guard let attributes = newAttributes else { return nil }

        guard MessagePatches.replaceVoiceAttributes(in: media.record, attributes: attributes, registeredUpload: true) else { return nil }
        return media
    }

    static func skipBoxed(_ reader: BufferReader) -> Bool {
        guard let signature = reader.readInt32() else { return false }
        return Api.parse(reader, signature: signature) != nil
    }

    static func rewriteMultiMedia(_ payload: Data, reader: BufferReader) -> NSData? {
        let vectorStart = Int(reader.offset)
        guard reader.readInt32() == 481674261 else { return nil }   // Vector
        guard let items = Api.parseVector(reader, elementSignature: 0,
                                          elementType: Api.InputSingleMedia.self) else { return nil }
        let vectorEnd = Int(reader.offset)

        var changed = false
        let rewritten: [Api.InputSingleMedia] = items.map { item in
            guard case let .inputSingleMedia(data) = item,
                  voiceMedia(from: data.media) != nil else { return item }
            changed = true
            return item
        }
        guard changed else { return nil }

        let vectorBuffer = Buffer()
        vectorBuffer.appendInt32(481674261)
        vectorBuffer.appendInt32(Int32(rewritten.count))
        for item in rewritten { item.serialize(vectorBuffer, true) }
        guard vectorBuffer.isValid else { return nil }

        var out = Data()
        out.append(payload.subdata(in: 0 ..< vectorStart))
        out.append(vectorBuffer.makeData())
        out.append(payload.subdata(in: vectorEnd ..< payload.count))
        return out as NSData
    }

    @objc static func rewriteVoiceUpload(_ data: NSData) -> NSData? {
        guard MessagePatches.Settings().videoToVoice else { return nil }

        let payload = data as Data
        let reader = BufferReader(Buffer(data: payload))
        guard let functionId = reader.readInt32() else { return nil }

        switch functionId {
        case TLMethodID.messagesSendMedia:   // messages.sendMedia
            guard let flags = reader.readInt32() else { return nil }
            guard skipBoxed(reader) else { return nil }                  // peer
            if (Int(flags) & (1 << 0)) != 0 {
                guard skipBoxed(reader) else { return nil }              // reply_to
            }
        case TLMethodID.messagesUploadMedia:  // messages.uploadMedia
            guard let flags = reader.readInt32() else { return nil }
            if (Int(flags) & (1 << 0)) != 0 {
                guard parseString(reader) != nil else { return nil }     // business_connection_id
            }
            guard skipBoxed(reader) else { return nil }                  // peer
        case TLMethodID.messagesSendMultiMedia:  // messages.sendMultiMedia — several clips picked at once
            guard let flags = reader.readInt32() else { return nil }
            guard skipBoxed(reader) else { return nil }                  // peer
            if (Int(flags) & (1 << 0)) != 0 {
                guard skipBoxed(reader) else { return nil }              // reply_to
            }
            return rewriteMultiMedia(payload, reader: reader)
        default:
            return nil
        }

        let mediaStart = Int(reader.offset)
        guard let signature = reader.readInt32(), signature == 58495792 else { return nil }
        guard let media = Api.parse(reader, signature: signature) as? Api.InputMedia else { return nil }
        let mediaEnd = Int(reader.offset)
        guard let rewritten = voiceMedia(from: media) else { return nil }

        let mediaBuffer = Buffer()
        rewritten.serialize(mediaBuffer, true)
        guard mediaBuffer.isValid else { return nil }

        var out = Data()
        out.append(payload.subdata(in: 0 ..< mediaStart))
        out.append(mediaBuffer.makeData())
        out.append(payload.subdata(in: mediaEnd ..< payload.count))
        return out as NSData
    }
}
