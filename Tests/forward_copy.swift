import Foundation
import TestSupport

private let copySource = Api.InputPeer.inputPeerUser(.init(userId: 42, accessHash: 123))
private let copyDestination = Api.InputPeer.inputPeerUser(.init(userId: 99, accessHash: 456))

private func copyPayload(_ ids: [Int32], flags: Int32 = 0, source: Api.InputPeer = copySource,
                         top: Int32? = nil, schedule: Int32? = nil, sendAs: Api.InputPeer? = nil) -> Data {
    Api.functions.messages.forwardMessages(flags: flags, fromPeer: source, id: ids,
        randomId: ids.map { 9000 + Int64($0) }, toPeer: copyDestination, topMsgId: top, replyTo: nil,
        scheduleDate: schedule, scheduleRepeatPeriod: nil, sendAs: sendAs, quickReplyShortcut: nil,
        effect: nil, videoTimestamp: nil, allowPaidStars: nil, suggestedPost: nil).1.makeData()
}

private func copyHistory(_ messages: [Api.Message]) -> Data {
    serialized(Api.messages.Messages.messages(.init(messages: messages, topics: [], chats: [], users: []))) as Data
}

private func copySent(_ sourceIds: [Int32], serverBase: Int32 = 100) -> Data {
    var updates = [Api.Update]()
    for (index, id) in sourceIds.enumerated() {
        let serverId = serverBase + Int32(index)
        updates.append(.updateMessageID(.init(id: serverId, randomId: 9000 + Int64(id))))
        updates.append(.updateNewMessage(.init(message: message(serverId, peer: .peerUser(.init(userId: 99))), pts: serverId, ptsCount: 1)))
    }
    return serialized(Api.Updates.updates(.init(updates: updates, users: [], chats: [], date: 1234, seq: 8))) as Data
}

private func copyPhoto(id: Int64 = 12, reference: String = "ref") -> Api.MessageMedia {
    .messageMediaPhoto(.init(flags: 1, photo: .photo(.init(flags: 0, id: id, accessHash: 22,
        fileReference: Buffer(data: Data(reference.utf8)), date: 1234,
        sizes: [.photoSize(.init(type: "x", w: 100, h: 100, size: 3))], videoSizes: nil, dcId: 2)), ttlSeconds: nil, video: nil))
}

private func copyDocument(size: Int64, id: Int64 = 50, attributes: [Api.DocumentAttribute]? = nil) -> Api.MessageMedia {
    .messageMediaDocument(.init(flags: 1, document: .document(.init(flags: 0, id: id, accessHash: 51,
        fileReference: Buffer(data: Data("docref".utf8)), date: 1234, mimeType: "audio/ogg", size: size,
        thumbs: nil, videoThumbs: nil, dcId: 2, attributes: attributes ?? [
            .documentAttributeFilename(.init(fileName: "voice.ogg")),
            .documentAttributeAudio(.init(flags: (1 << 10) | (1 << 2), duration: 3, title: nil, performer: nil, waveform: Buffer(data: Data([1, 2, 3]))))
        ])), altDocuments: nil, videoCover: nil, videoTimestamp: nil, ttlSeconds: nil))
}

private func copyFile(_ bytes: Data) -> Data {
    serialized(Api.upload.File.file(.init(type: .fileUnknown, mtime: 1234, bytes: Buffer(data: bytes)))) as Data
}

private func copyConstructor(_ bytes: Data) -> Int32 { BufferReader(Buffer(data: bytes)).readInt32()! }

func testForwardCopies(rust: Bool = false) {
    flags("disableForwardRestriction")
    let directory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("tgextra-copy-tests-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    func run(_ payload: Data, _ replies: [String: [Any]], initial: String? = nil, cancel: Bool = false,
             parallel: Bool = false, account: String = "account-1", subdirectory: String = UUID().uuidString) -> [String: Any] {
        var fixture: [String: Any] = ["payload": payload, "replies": replies, "cancel": cancel, "account": account, "rust": rust, "parallel": parallel]
        if let initial = initial { fixture["initialError"] = initial }
        return TGExtraRunForwardCopyScenario(fixture, directory.appendingPathComponent(subdirectory)) as! [String: Any]
    }
    func calls(_ scenario: [String: Any]) -> [Int32] {
        (scenario["payloads"] as! [Data]).map(copyConstructor)
    }
    let payload = copyPayload([1])
    let history = copyHistory([message(1, text: "Text 😀")])
    let sent = copySent([1])
    let crowded = directory.appendingPathComponent("crowded")
    try! FileManager.default.createDirectory(at: crowded, withIntermediateDirectories: true)
    let stale = Date(timeIntervalSinceNow: -365 * 86400)
    let unfinished: [String: Any] = ["account": "inactive-account", "updated": stale,
                                     "payload": payload, "requests": [], "results": [:]]
    let unfinishedBytes = try! PropertyListSerialization.data(fromPropertyList: unfinished, format: .binary, options: 0)
    for index in 0..<128 {
        try! unfinishedBytes.write(to: crowded.appendingPathComponent("unfinished-\(index).plist"))
    }
    let completed: [String: Any] = ["complete": true, "updated": stale]
    let completedBytes = try! PropertyListSerialization.data(fromPropertyList: completed, format: .binary, options: 0)
    let expired = crowded.appendingPathComponent("old-completed.plist")
    try! completedBytes.write(to: expired)
    let crowdedCopy = run(payload, ["1673946374": [history], "-17526942": [sent]], subdirectory: "crowded")
    check(crowdedCopy["error"] as! String == "", "Unfinished journals from other accounts do not block a new copy")
    check(!FileManager.default.fileExists(atPath: expired.path), "Expired completed journals are still pruned")
    for index in 0..<128 {
        check((try? Data(contentsOf: crowded.appendingPathComponent("unfinished-\(index).plist"))) == unfinishedBytes,
              "Keep unfinished journals intact for safe retries")
    }
    let crowdedRetry = run(payload, [:], subdirectory: "crowded")
    check(crowdedRetry["error"] as! String == "" && calls(crowdedRetry).isEmpty,
          "A retry after journal saturation reuses the saved result without duplicate sends")
    let plan = ForwardCopyPlan(payload: payload)!
    check(plan.prepare(response: history) && plan.buildRequests(), "Prepare text copy without host Swift APIs")
    check(plan.downloads.isEmpty, "Text copies need no file requests")
    let textRequest = plan.requests[0]["payload"] as! Data
    let textReader = BufferReader(Buffer(data: textRequest))
    check(textReader.readInt32() == -17526942 && textReader.readInt32() == (1 << 3), "Forward becomes sendMessage with entities")
    _ = Api.parse(textReader, signature: textReader.readInt32()!) as! Api.InputPeer
    check(parseString(textReader) == "Text 😀" && textReader.readInt64() == 9001, "Text, Unicode and original random_id survive")
    check(textReader.readInt32() == 481674261 && textReader.readInt32() == 1, "Formatting entities are present")
    guard case .messageEntityBold = Api.parse(textReader, signature: textReader.readInt32()!) as! Api.MessageEntity else { fatalError("Expected bold entity") }
    check(textReader.offset == UInt(textRequest.count), "Text request has no leftover forward fields")
    let mentionMessage = message(1, text: "Alice")
    messageData(mentionMessage).entities = [.messageEntityMentionName(.init(offset: 0, length: 5, userId: 77))]
    let mentionPlan = ForwardCopyPlan(payload: payload)!
    check(mentionPlan.prepare(response: copyHistory([mentionMessage])) && mentionPlan.buildRequests(), "Mention preflight")
    let mentionReader = BufferReader(Buffer(data: (mentionPlan.requests[0]["payload"] as! Data)))
    _ = mentionReader.readInt32(); _ = mentionReader.readInt32(); _ = Api.parse(mentionReader, signature: mentionReader.readInt32()!)
    _ = parseString(mentionReader); _ = mentionReader.readInt64(); _ = mentionReader.readInt32(); _ = mentionReader.readInt32()
    guard case let .inputMessageEntityMentionName(mention) = Api.parse(mentionReader, signature: mentionReader.readInt32()!) as! Api.MessageEntity,
          case let .inputUserFromMessage(mentionedUser) = mention.userId else { fatalError("Expected input mention") }
    check(mentionedUser.userId == 77 && mentionedUser.msgId == 1, "Output-only mention entities become resolvable input entities")
    for length in 0..<payload.count {
        check(ForwardCopyPlan(payload: payload.prefix(length)) == nil, "Reject truncated forward request at \(length)")
    }
    check(ForwardCopyPlan(payload: payload + Data([0])) == nil, "Reject unknown trailing request fields")
    var unknownFlags = payload
    unknownFlags[7] |= 0x40
    check(ForwardCopyPlan(payload: unknownFlags) == nil, "Unknown flags pass through to host without reinterpretation")
    check(ForwardCopyPlan.operationKey(account: "account-1", payload: payload) != ForwardCopyPlan.operationKey(account: "account-2", payload: payload), "Journal keys are account-scoped")

    let topic = ForwardCopyPlan(payload: copyPayload([1], flags: (1 << 5) | (1 << 9) | (1 << 10) | (1 << 13),
        top: 7, schedule: 10000, sendAs: .inputPeerSelf))!
    check(topic.prepare(response: history) && topic.buildRequests(), "Topic/scheduled/send-as copy is supported")
    let topicReader = BufferReader(Buffer(data: (topic.requests[0]["payload"] as! Data)))
    _ = topicReader.readInt32(); let topicFlags = topicReader.readInt32()!
    check(topicFlags & 1 != 0 && topicFlags & (1 << 5) != 0 && topicFlags & (1 << 10) != 0 && topicFlags & (1 << 13) != 0,
          "Forward and send flags are mapped by meaning")
    _ = Api.parse(topicReader, signature: topicReader.readInt32()!)
    guard case let .inputReplyToMessage(reply) = Api.parse(topicReader, signature: topicReader.readInt32()!) as! Api.InputReplyTo else { fatalError("Expected topic reply") }
    check(reply.topMsgId == 7 && reply.replyToMsgId == 7, "Topic moves into reply_to")

    let sourceChannel = Api.InputPeer.inputPeerChannel(.init(channelId: 77, accessHash: 10))
    let channelPlan = ForwardCopyPlan(payload: copyPayload([1], source: sourceChannel))!
    check(copyConstructor(channelPlan.sourceRequest!) == -1383294429, "Channel source uses channels.getMessages")
    check(!channelPlan.prepare(response: history), "A message from another peer cannot satisfy source lookup")
    check(plan.normalize(response: sent, confirmation: nil, batch: 0) != nil, "Real Updates complete the original random_id")
    check(plan.normalize(response: copySent([2]), confirmation: nil, batch: 0) == nil, "An unrelated random_id cannot report success")
    check(plan.normalize(response: serialized(Api.Updates.updatesTooLong) as Data, confirmation: nil, batch: 0) == nil, "No success without message confirmation")
    let compact = serialized(Api.Updates.updateShortSentMessage(.init(flags: 0, id: 100, pts: 200,
        ptsCount: 1, date: 1234, media: nil, entities: nil, ttlPeriod: nil))) as Data
    check(plan.confirmationRequest(response: compact) != nil && plan.normalize(response: compact, confirmation: nil, batch: 0) == nil,
          "Compact send replies require a real fetched server message")
    let confirmation = copyHistory([message(100, peer: .peerUser(.init(userId: 99)))])
    check(plan.normalize(response: compact, confirmation: confirmation, batch: 0) != nil, "Compact reply retains server ID and pts after confirmation")

    let normal = run(payload, [:], initial: "")
    check(calls(normal).isEmpty && normal["error"] as! String == "" && normal["completions"] as! Int == 1, "Successful ordinary forwarding is untouched")
    let denied = run(payload, [:], initial: "CHAT_WRITE_FORBIDDEN")
    check(calls(denied).isEmpty && denied["error"] as! String == "CHAT_WRITE_FORBIDDEN", "Only the exact forward restriction triggers a copy")
    flags()
    let disabled = run(payload, [:])
    check(calls(disabled).isEmpty && disabled["error"] as! String == "CHAT_FORWARDS_RESTRICTED", "Disabled setting never starts a copy")
    flags("disableForwardRestriction")
    let unresolved = run(payload, [:], account: "unknown")
    check(calls(unresolved).isEmpty && unresolved["error"] as! String == "CHAT_FORWARDS_RESTRICTED", "Unknown accounts cannot borrow a session")
    let copied = run(payload, ["1673946374": [history], "-17526942": [sent]])
    check(calls(copied) == [1673946374, -17526942] && copied["error"] as! String == "" && copied["completions"] as! Int == 1,
          "Objective-C hook replaces the failed forward with a confirmed text send")

    if rust {
        func rustCase(_ options: [String: Any], _ replies: [String: [Any]]) -> [String: Any] {
            var fixture = options
            fixture["rust"] = true; fixture["payload"] = payload; fixture["replies"] = replies
            return TGExtraRunForwardCopyScenario(fixture, directory.appendingPathComponent(UUID().uuidString)) as! [String: Any]
        }
        let denied406 = rustCase(["initialCode": 406], ["1673946374": [history], "-17526942": [sent]])
        check(denied406["error"] as! String == "" && calls(denied406) == [1673946374, -17526942], "Rust also recovers a 406 forward refusal")
        let dependent = rustCase(["dependent": true], ["1673946374": [history], "-17526942": [sent]])
        check(dependent["sequence"] as! [String] == ["completed", "dependent"], "Rust dependents wait until the reconstructed forward completes")
        check((dependent["activity"] as! Int) >= 2, "Rust helpers keep the host's liveness bookkeeping current")
        let chain = rustCase(["chain": true], ["1673946374": [history], "-17526942": [sent]])
        check(chain["sequence"] as! [String] == ["completed", "dependent", "grandchild"], "Transitive Rust dependencies preserve completion order")
        let cancelledDependent = rustCase(["dependent": true, "cancelDependent": true], ["1673946374": [history], "-17526942": [sent]])
        check(cancelledDependent["sequence"] as! [String] == ["completed"], "Cancellation removes a held dependency before it reaches Rust")
        let destroyed = rustCase(["destroy": true], ["1673946374": [["hold": true]]])
        check(destroyed["completions"] as! Int == 0 && destroyed["cancellations"] as! Int == 1, "Rust session destruction cancels recovery and its active helper")
        let noContext = rustCase(["noContext": true], [:])
        check(noContext["error"] as! String == "CHAT_FORWARDS_RESTRICTED" && calls(noContext).isEmpty, "Rust recovery cannot borrow a missing account context")
    }

    // A compact ACK is durable even if the following getMessages fails. Retry
    // confirms the existing message and never issues sendMessage again.
    let failedConfirmation = run(payload, ["1673946374": [history, ["error": "NETWORK_FAILED"]], "-17526942": [compact]], subdirectory: "compact")
    check(failedConfirmation["error"] as! String == "NETWORK_FAILED", "A failed confirmation does not pretend success")
    let retryConfirmation = run(payload, ["1673946374": [confirmation]], subdirectory: "compact")
    check(calls(retryConfirmation) == [1673946374] && retryConfirmation["error"] as! String == "", "Retry uses the saved ACK without resending")
    let replay = run(payload, [:], subdirectory: "compact")
    check(calls(replay).isEmpty && replay["error"] as! String == "", "A completed operation replays real stored results")

    let two = copyPayload([1, 2])
    let twoHistory = copyHistory([message(1), message(2)])
    let partial = run(two, ["1673946374": [twoHistory], "-17526942": [sent, ["error": "CHAT_WRITE_FORBIDDEN"]]], subdirectory: "partial")
    check(partial["error"] as! String == "CHAT_WRITE_FORBIDDEN", "A partial selection preserves the actual error")
    let resumed = run(two, ["-17526942": [copySent([2], serverBase: 101)]], subdirectory: "partial")
    check(calls(resumed) == [-17526942] && resumed["error"] as! String == "", "Only the unconfirmed message is sent on retry")
    let merged = parsed(resumed["result"] as! NSData, as: Api.Updates.self)
    guard case let .updates(mergedData) = merged else { fatalError("Expected Updates") }
    check(mergedData.updates.count == 4 && mergedData.seq == 0, "Combined real results retain both original ID mappings")

    let unsupported = message(2, media: .messageMediaDice(.init(flags: 0, value: 2, emoticon: "🎲", gameOutcome: nil)))
    let invalidSelection = run(two, ["1673946374": [copyHistory([message(1), unsupported])]])
    check(calls(invalidSelection) == [1673946374] && invalidSelection["error"] as! String == "TGEXTRA_COPY_UNSUPPORTED", "Preflight rejects an unsupported selection before any sends")
    let cancelled = run(payload, ["1673946374": [["hold": true]]], cancel: true)
    check(cancelled["completions"] as! Int == 0 && cancelled["cancellations"] as! Int == 1, "Cancellation drops the pending helper without a completion")

    let photoMessage = message(1, media: copyPhoto())
    let photoPlan = ForwardCopyPlan(payload: payload)!
    check(photoPlan.prepare(response: copyHistory([photoMessage])) && photoPlan.downloads.count == 1, "A photo selects its full-size resource")
    check(photoPlan.downloadRequest(index: 0, offset: 1) == nil, "Download offsets stay aligned to MTProto chunks")
    check(photoPlan.refreshDownload(response: copyHistory([message(1, media: copyPhoto(reference: "new"))]), index: 0), "Expired file references can refresh for the same original")
    check(!photoPlan.refreshDownload(response: copyHistory([message(1, media: copyPhoto(id: 99))]), index: 0), "A replaced attachment cannot splice into an in-progress download")
    let uploadedPhoto = serialized(copyPhoto(id: 120)) as Data
    let trueReply = serialized(Api.Bool.boolTrue) as Data
    let photoCopy = run(payload, ["1673946374": [copyHistory([photoMessage])],
        "-1101843010": [copyFile(Data([1, 2, 3]))], "-1291540959": [trueReply],
        "345405816": [uploadedPhoto], "53536639": [sent]])
    check(calls(photoCopy) == [1673946374, -1101843010, -1291540959, 345405816, 53536639] && photoCopy["error"] as! String == "",
          "Media is downloaded from its DC, uploaded afresh and sent as a new message")
    let photoPayloads = photoCopy["payloads"] as! [Data]
    let uploadReader = BufferReader(Buffer(data: photoPayloads[3]))
    _ = uploadReader.readInt32(); _ = uploadReader.readInt32(); _ = Api.parse(uploadReader, signature: uploadReader.readInt32()!)
    guard case let .inputMediaUploadedPhoto(uploaded) = Api.parse(uploadReader, signature: uploadReader.readInt32()!) as! Api.InputMedia,
          case let .inputFile(file) = uploaded.file else { fatalError("Expected fresh uploaded photo") }
    check(file.md5Checksum == "5289df737df57326fcdd22597afb1fac" && file.parts == 1, "Small uploads use the checksum of the downloaded bytes")

    let refreshed = run(payload, ["1673946374": [copyHistory([photoMessage]), copyHistory([message(1, media: copyPhoto(reference: "fresh"))])],
        "-1101843010": [["error": "FILE_REFERENCE_EXPIRED"], copyFile(Data([1, 2, 3]))], "-1291540959": [trueReply],
        "345405816": [uploadedPhoto], "53536639": [sent]])
    check(calls(refreshed).filter { $0 == 1673946374 }.count == 2 && refreshed["error"] as! String == "", "A stale download reference is refreshed once")
    let truncated = run(payload, ["1673946374": [copyHistory([photoMessage])], "-1101843010": [copyFile(Data([1]))]])
    check(calls(truncated) == [1673946374, -1101843010] && truncated["error"] as! String == "TGEXTRA_COPY_FILE_INVALID", "Incomplete downloads cannot be uploaded or reported as sent")

    let docSize: Int64 = 524289
    let docMessage = message(1, media: copyDocument(size: docSize))
    let docCopy = run(payload, ["1673946374": [copyHistory([docMessage])],
        "-1101843010": [copyFile(Data(repeating: 7, count: 524288)), copyFile(Data([8]))],
        "-1291540959": [trueReply, trueReply], "345405816": [serialized(copyDocument(size: docSize, id: 150)) as Data], "53536639": [sent]])
    check(docCopy["error"] as! String == "" && calls(docCopy).filter { $0 == -1291540959 }.count == 2, "Files stream through bounded chunks, including a short final part")
    let docPayloads = docCopy["payloads"] as! [Data]
    let docUpload = BufferReader(Buffer(data: docPayloads.first(where: { copyConstructor($0) == 345405816 })!))
    _ = docUpload.readInt32(); _ = docUpload.readInt32(); _ = Api.parse(docUpload, signature: docUpload.readInt32()!)
    guard case let .inputMediaUploadedDocument(doc) = Api.parse(docUpload, signature: docUpload.readInt32()!) as! Api.InputMedia else { fatalError("Expected document") }
    check(doc.mimeType == "audio/ogg" && doc.attributes.count == 2, "Document MIME and attributes are retained")
    guard case let .documentAttributeAudio(audio) = doc.attributes[1] else { fatalError("Expected audio") }
    check(audio.flags & (1 << 10) != 0 && audio.waveform?.makeData() == Data([1, 2, 3]), "Voice flag and waveform survive re-upload")
    let chunks = (0..<8).map { Data(repeating: UInt8($0 + 1), count: $0 == 7 ? 19 : 524288) }
    let parallelSize = Int64(chunks.reduce(0) { $0 + $1.count })
    let cancelledWindow = run(payload, ["1673946374": [copyHistory([message(1, media: copyDocument(size: parallelSize))])],
        "-1101843010": Array(repeating: ["hold": true] as [String: Any], count: 4)], cancel: true)
    check(cancelledWindow["completions"] as! Int == 0 && cancelledWindow["cancellations"] as! Int == 4,
          "Cancellation retires every active file request without completing the original forward")
    let parallel = run(payload, ["1673946374": [copyHistory([message(1, media: copyDocument(size: parallelSize))])],
        "-1101843010": chunks.map(copyFile), "-1291540959": Array(repeating: trueReply, count: chunks.count),
        "345405816": [serialized(copyDocument(size: parallelSize, id: 151)) as Data], "53536639": [sent]], parallel: true)
    check(parallel["error"] as! String == "" && parallel["maxFiles"] as! Int == 4,
          "Use four concurrent download requests")
    check((parallel["fileOrder"] as! [Int]).first != 0 && parallel["overlap"] as! Bool,
          "Handle out-of-order chunks and upload while downloading")
    let parallelUploads = (parallel["payloads"] as! [Data]).filter { copyConstructor($0) == -1291540959 }
    check(parallelUploads.count == chunks.count, "Upload each part exactly once")
    for payload in parallelUploads {
        let reader = BufferReader(Buffer(data: payload))
        _ = reader.readInt32(); _ = reader.readInt64()
        let part = Int(reader.readInt32()!)
        check(parseBytes(reader)?.makeData() == chunks[part], "Ordered disk assembly preserves uploaded part bytes")
    }
    let bigPlan = ForwardCopyPlan(payload: payload)!
    check(bigPlan.prepare(response: copyHistory([message(1, media: copyDocument(size: 11 * 1024 * 1024))])), "Large files are supported below the upload ceiling")
    let bigRequest = bigPlan.mediaUploadRequest(index: 0, fileId: 7, parts: 22, md5: "")!
    let bigReader = BufferReader(Buffer(data: bigRequest)); _ = bigReader.readInt32(); _ = bigReader.readInt32()
    _ = Api.parse(bigReader, signature: bigReader.readInt32()!)
    guard case let .inputMediaUploadedDocument(bigMedia) = Api.parse(bigReader, signature: bigReader.readInt32()!) as! Api.InputMedia,
          case .inputFileBig = bigMedia.file else { fatalError("Expected inputFileBig") }
    check(copyConstructor(ForwardCopyPlan.uploadRequest(fileId: 7, part: 0, total: 22, bytes: Data([1]), big: true)!) == -562337987, "Large uploads use saveBigFilePart")

    let albumMessages = [message(1, media: copyPhoto()), message(2, media: copyPhoto(id: 13))]
    for m in albumMessages { let data = messageData(m); data.flags |= 1 << 17; data.groupedId = 555 }
    let album = ForwardCopyPlan(payload: copyPayload([1, 2], flags: (1 << 8) | (1 << 12)))!
    check(album.prepare(response: copyHistory(albumMessages)), "Album preflight")
    check(album.registerMedia(response: uploadedPhoto, index: 0) && album.registerMedia(response: uploadedPhoto, index: 1) && album.buildRequests(), "Album builds after all uploads are ready")
    check(album.requests.count == 1 && copyConstructor(album.requests[0]["payload"] as! Data) == 469278068, "Album uses one sendMultiMedia RPC")
    let albumReader = BufferReader(Buffer(data: (album.requests[0]["payload"] as! Data)))
    _ = albumReader.readInt32(); _ = albumReader.readInt32(); _ = Api.parse(albumReader, signature: albumReader.readInt32()!)
    check(albumReader.readInt32() == 481674261 && albumReader.readInt32() == 2, "Album contains both items")
    guard case let .inputSingleMedia(albumItem) = Api.parse(albumReader, signature: albumReader.readInt32()!) as! Api.InputSingleMedia else { fatalError("Expected album item") }
    check(albumItem.message.isEmpty && albumItem.entities == nil && albumItem.randomId == 9001, "Hide captions applies to albums without losing random_id")
    let albumCopy = run(copyPayload([1, 2], flags: 1 << 8), ["1673946374": [copyHistory(albumMessages)],
        "-1101843010": [copyFile(Data([1, 2, 3])), copyFile(Data([4, 5, 6]))],
        "-1291540959": [trueReply, trueReply], "345405816": [uploadedPhoto, uploadedPhoto],
        "469278068": [copySent([1, 2])]])
    check(albumCopy["error"] as! String == "" && calls(albumCopy).last == 469278068 &&
          calls(albumCopy).filter({ $0 == 345405816 }).count == 2, "Entire album is uploaded before one confirmed sendMultiMedia")
    let scheduled = serialized(Api.Updates.updates(.init(updates: [
        .updateMessageID(.init(id: 100, randomId: 9001)),
        .updateNewScheduledMessage(.init(message: message(100, peer: .peerUser(.init(userId: 99)))))
    ], users: [], chats: [], date: 1234, seq: 0))) as Data
    check(topic.normalize(response: scheduled, confirmation: nil, batch: 0) != nil, "Scheduled replies confirm the same original random_id")
    let separate = ForwardCopyPlan(payload: copyPayload([1, 2]))!
    check(separate.prepare(response: twoHistory) && separate.buildRequests() && separate.requests.count == 2, "Independent posts stay independent")
    let expiring = copyPhoto()
    if case let .messageMediaPhoto(p) = expiring { p.flags |= 4; p.ttlSeconds = 10 }
    check(!photoPlan.prepare(response: copyHistory([message(1, media: expiring)])), "Disappearing media is not copied")
    print("PASS protected-forward copies via \(rust ? "Rust FFI" : "MtProtoKit"): text, media, albums, accounts, cancellation, compact ACKs and partial retries")
}
