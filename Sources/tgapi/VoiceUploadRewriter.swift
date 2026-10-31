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
        guard MessagePatches.Settings().videoToVoice,
              case let .inputMediaUploadedDocument(data) = media else { return nil }

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

    @objc static func rewriteVoiceUpload(_ data: NSData) -> NSData? {
        let settings = MessagePatches.Settings()
        guard settings.videoToVoice || settings.videoToRound, let method = requestMethod(data),
              [TLMethodID.messagesSendMedia, .messagesUploadMedia, .messagesSendMultiMedia].contains(method),
              let record = request(data) else { return nil }
        var changed = false
        if method == .messagesSendMultiMedia {
            guard let items = record["multiMedia"] as? [TLRecord] else { return nil }
            for item in items {
                guard let mediaRecord = item["media"] as? TLRecord,
                      let media = Api.InputMedia(mediaRecord),
                      (voiceMedia(from: media) ?? roundVideoMedia(from: media)) != nil else { continue }
                changed = true
            }
        } else if let mediaRecord = record["media"] as? TLRecord,
                  let media = Api.InputMedia(mediaRecord) {
            changed = (voiceMedia(from: media) ?? roundVideoMedia(from: media)) != nil
        }
        guard changed else { return nil }
        return record.serializedData().map { $0 as NSData }
    }
}
