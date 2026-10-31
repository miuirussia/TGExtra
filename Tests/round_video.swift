import Foundation

func testRoundVideoUploads() {
    let peer = Api.InputPeer.inputPeerUser(.init(userId: 42, accessHash: 3))
    func media(_ name: String) -> Api.InputMedia {
        let file = Api.InputFile.inputFile(.init(id: 321, parts: 1, name: name, md5Checksum: "hash"))
        // Telegram's file picker sets nosound_video and force_file for an MP4 file.
        return .inputMediaUploadedDocument(.init(flags: (1 << 3) | (1 << 4), file: file, thumb: nil, mimeType: "video/mp4",
            attributes: [.documentAttributeFilename(.init(fileName: name))], stickers: nil,
            videoCover: nil, videoTimestamp: nil, ttlSeconds: nil))
    }
    func send(_ media: Api.InputMedia) -> Data {
        Api.functions.messages.sendMedia(flags: 0, peer: peer, replyTo: nil, media: media,
            message: "caption", randomId: 987, replyMarkup: nil, entities: nil, scheduleDate: nil,
            scheduleRepeatPeriod: nil, sendAs: nil, quickReplyShortcut: nil, effect: nil,
            allowPaidStars: nil, suggestedPost: nil).1.makeData()
    }
    func isRound(_ record: TLRecord) -> Bool {
        guard let attributes = record["attributes"] as? [TLRecord], attributes.count == 1,
              case let .documentAttributeVideo(video)? = Api.DocumentAttribute(attributes[0]) else { return false }
        return video.flags & 1 != 0 && video.w == 384 && video.h == 384 && abs(video.duration - 2.5) < 0.01
    }
    let clip = media("round-fixture.mp4")
    let payload = send(clip)
    flags("TGExtraVideoToRound")
    check(TLParser.rewriteVoiceUpload(payload as NSData) == nil, "Ordinary MP4 uploads remain unchanged")
    TLParser.registerRoundVideoUpload(withFileName: "round-fixture.mp4", duration: 2.5)
    flags("TGExtraVideoToVoice")
    check(TLParser.rewriteVoiceUpload(payload as NSData) == nil, "Voice setting does not enable circles")
    flags("TGExtraVideoToRound")
    let changed = TLParser.rewriteVoiceUpload(payload as NSData)!
    let request = TLParser.request(changed)!
    check(isRound(request["media"] as! TLRecord), "Registered square upload has round video attributes")
    check((request["media"] as! TLRecord)["flags"] as? Int32 == 1 << 3,
          "Round upload clears force_file and preserves nosound_video")
    check(request["message"] as? String == "caption" && request["randomId"] as? Int64 == 987,
          "Round rewrite preserves caption and request identity")
    check(TLParser.rewriteVoiceUpload(changed) == nil, "Round rewrite is idempotent")
    let upload = Api.functions.messages.uploadMedia(flags: 0, businessConnectionId: nil,
        peer: peer, media: clip).1.makeData()
    let uploaded = TLParser.rewriteVoiceUpload(upload as NSData)!
    check(isRound(TLParser.request(uploaded)!["media"] as! TLRecord), "Round conversion covers uploadMedia")
    check((TLParser.request(uploaded)!["media"] as! TLRecord)["flags"] as? Int32 == 1 << 3,
          "uploadMedia also clears force_file before server-side document classification")
    let items = [Api.InputSingleMedia.inputSingleMedia(.init(flags: 0, media: clip,
        randomId: 111, message: "round", entities: nil)),
        .inputSingleMedia(.init(flags: 0, media: media("ordinary.mp4"), randomId: 222,
        message: "ordinary", entities: nil))]
    let batch = Api.functions.messages.sendMultiMedia(flags: 0, peer: peer, replyTo: nil,
        multiMedia: items, scheduleDate: nil, sendAs: nil, quickReplyShortcut: nil,
        effect: nil, allowPaidStars: nil).1.makeData()
    let rewrittenBatch = TLParser.rewriteVoiceUpload(batch as NSData)!
    let records = TLParser.request(rewrittenBatch)!["multiMedia"] as! [TLRecord]
    check(isRound(records[0]["media"] as! TLRecord) && !isRound(records[1]["media"] as! TLRecord),
          "Mixed batches only convert registered clips")
    check((records[0]["media"] as! TLRecord)["flags"] as? Int32 == 1 << 3 &&
          (records[1]["media"] as! TLRecord)["flags"] as? Int32 == (1 << 3) | (1 << 4),
          "Mixed batches preserve force_file on ordinary uploads")
    flags()
    check(TLParser.rewriteVoiceUpload(payload as NSData) == nil, "Disabled round setting bypasses rewrite")
    flags("TGExtraVideoToRound")
    for duration in [Double.nan, .infinity, -1, 0, 61] {
        TLParser.registerRoundVideoUpload(withFileName: "invalid.mp4", duration: duration)
    }
    check(TLParser.rewriteVoiceUpload(send(media("invalid.mp4")) as NSData) == nil,
          "Invalid round durations never enter the registry")
    flags()
    print("PASS round video uploads: registration, setting isolation, attributes, force_file, captions, uploadMedia, mixed batches and invalid durations")
}
