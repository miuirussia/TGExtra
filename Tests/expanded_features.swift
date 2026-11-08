import Foundation
import TestSupport

private func featureRequest(_ method: TLMethodID, _ fields: [String: Any]) -> NSData {
    let record = TLRecord(function: method)
    record.fields = fields
    record.normalizeOptionalFlags()
    return record.serializedData()! as NSData
}

private func featureRecord(_ bytes: NSData) -> TLRecord {
    let reader = BufferReader(Buffer(nsData: bytes))
    return TLCodec.parse(reader, descriptor: TLCodec.descriptor(reader.readInt32()!)!)!
}

func testExpandedFeatures() {
    let keys = ["TGExtraGhostModeEnabled", "TGExtraGhostReadOnReply", "TGExtraGhostKeepVoiceUnread", "disableMessageReadReceipt",
        "disableTypingStatus", "disableStoriesReadReceipt", "disableMentionReadReceipt", "disableReactionReadReceipt",
        "TGExtraSaveDeletedStories", "TGExtraAudioToVoice", "TGExtraForwardDropAuthor"]
    let saved = defaults.dictionaryRepresentation()
    defer {
        for key in keys {
            if let value = saved[key] { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
        }
        TLParser.clearPendingGhostReads()
        TLParser.clearMessageData()
        flags()
    }
    flags()
    TLParser.clearMessageData()
    for key in keys { defaults.set(false, forKey: key) }
    for key in ["TGExtraGhostModeEnabled", "disableMessageReadReceipt", "disableTypingStatus", "disableStoriesReadReceipt"] { defaults.set(true, forKey: key) }
    let peer = Api.InputPeer.inputPeerUser(.init(userId: 42, accessHash: 1)).record
    let other = Api.InputPeer.inputPeerUser(.init(userId: 43, accessHash: 2)).record
    let secret = TLRecord(type: "InputEncryptedChat", constructor: "inputEncryptedChat")
    secret.fields = ["chatId": Int32(42), "accessHash": Int64(1)]
    let discussion = featureRequest(.messagesReadDiscussion, ["peer": peer, "msgId": Int32(100), "readMaxId": Int32(200)])
    let secretRead = featureRequest(.messagesReadEncryptedHistory, ["peer": secret, "maxDate": Int32(200)])
    let typing = featureRequest(.messagesSetEncryptedTyping, ["peer": secret, "typing": Api.Bool.boolTrue.record])
    let storyRead = featureRequest(.storiesIncrementViews, ["peer": peer, "id": [Int32(1)]])
    for payload in [discussion, secretRead, typing, storyRead] {
        check(TLParser.fakeResponseForPayload(payload) == serialized(Api.Bool.boolTrue), "Expanded ghost requests use schema-compatible replies")
    }
    TGExtraTestSetGhostException(42, true)
    check(TLParser.fakeResponseForPayload(discussion) == nil && TLParser.fakeResponseForPayload(storyRead) == nil, "Exceptions cover discussion reads and profile story views")
    check(TLParser.fakeResponseForPayload(secretRead) != nil, "Encrypted chat IDs cannot inherit user exceptions")
    TGExtraTestSetGhostException(42, false)
    defaults.set(false, forKey: "TGExtraGhostModeEnabled")
    for payload in [discussion, secretRead, typing, storyRead] { check(TLParser.fakeResponseForPayload(payload) == nil, "Ghost master switch controls new requests") }
    defaults.set(true, forKey: "TGExtraGhostModeEnabled")
    defaults.set(true, forKey: "TGExtraGhostReadOnReply")
    defaults.set(false, forKey: "disableMessageReadReceipt")
    check(TLParser.fakeResponseForPayload(discussion) != nil, "Read-on-reply hides history independently of the permanent receipt switch")
    func historyRead(_ maximum: Int32) -> NSData { featureRequest(.messagesReadHistory, ["peer": peer, "maxId": maximum]) }
    func send(_ target: TLRecord? = nil, scheduled: Bool = false, thread: Int32? = nil) -> NSData {
        var fields: [String: Any] = ["flags": Int32(0), "peer": target ?? peer, "message": "Reply", "randomId": Int64(123)]
        if scheduled { fields["scheduleDate"] = Int32(999) }
        if let thread = thread {
            let reply = TLRecord(type: "InputReplyTo", constructor: "inputReplyToMessage")
            reply.fields = ["flags": Int32(0), "replyToMsgId": thread, "topMsgId": thread]
            reply.normalizeOptionalFlags(); fields["replyTo"] = reply
        }
        return featureRequest(.messagesSendMessage, fields)
    }
    check(TGExtraTestGhostReply(historyRead(50) as Data, send() as Data, testAccount, true, false).isEmpty, "Failed sends must not publish reads")
    check(TGExtraTestGhostReply(historyRead(50) as Data, send() as Data, testAccount, false, true).count == 1, "Successful sends replay the blocked read")
    check(!TLParser.pendingGhostReadsAfterSend(send(), account: testAccount).isEmpty, "Failed read requests remain retryable")
    check(TGExtraTestGhostReply(nil, send() as Data, testAccount, false, false).count == 1, "Read acknowledgements finish the replay")
    check(TLParser.pendingGhostReadsAfterSend(send(), account: testAccount).isEmpty, "Successful replays empty their queue")
    let journal = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: journal) }
    for failed in [true, false] {
        TLParser.noteBlockedRead(historyRead(50), account: testAccount)
        let result = TGExtraRunForwardCopyScenario(["rust": true, "payload": send() as Data, "account": testAccount,
            "initialError": failed ? "TEST_SEND_FAILED" : "", "initialResult": serialized(Api.Updates.updates(.init(updates: [], users: [], chats: [], date: 100, seq: 1))) as Data,
            "replies": [String(TLMethodID.messagesReadHistory.id!): [serialized(Api.messages.AffectedMessages.affectedMessages(.init(pts: 1, ptsCount: 1))) as Data]]], journal) as! [String: Any]
        let reads = result["payloads"] as! [Data]
        check(reads.contains(historyRead(50) as Data) == !failed, "Rust publishes history reads only after successful sends")
        TLParser.clearPendingGhostReads()
    }
    for maximum: Int32 in [100, 200, 150] { TLParser.noteBlockedRead(historyRead(maximum), account: testAccount) }
    TLParser.noteBlockedRead(discussion, account: testAccount)
    TLParser.noteBlockedRead(storyRead, account: testAccount)
    TLParser.noteBlockedRead(historyRead(300), account: "account-2")
    check(TLParser.pendingGhostReadsAfterSend(send(), account: testAccount) == [historyRead(200) as Data], "Coalesce watermarks without releasing unrelated discussion threads")
    check(TLParser.pendingGhostReadsAfterSend(send(thread: 100), account: testAccount).count == 2, "Replies release their own discussion thread")
    func forwardToThread(_ thread: Int32?, target: TLRecord? = nil, scheduled: Bool = false) -> NSData {
        var fields: [String: Any] = ["flags": Int32(0), "fromPeer": other, "id": [Int32(1)],
            "randomId": [Int64(123)], "toPeer": target ?? peer]
        if let thread = thread { fields["topMsgId"] = thread }
        if scheduled { fields["scheduleDate"] = Int32(999) }
        return featureRequest(.messagesForward, fields)
    }
    check(TLParser.pendingGhostReadsAfterSend(forwardToThread(100), account: testAccount) == [historyRead(200) as Data, discussion as Data],
          "Forwards release reads for their top-level destination thread")
    for thread: Int32? in [nil, 101] {
        check(TLParser.pendingGhostReadsAfterSend(forwardToThread(thread), account: testAccount) == [historyRead(200) as Data],
              "Forwards outside the discussion cannot publish its reads")
    }
    check(TLParser.pendingGhostReadsAfterSend(forwardToThread(100, target: other), account: testAccount).isEmpty,
          "Forward threads cannot publish another chat's reads")
    check(TLParser.pendingGhostReadsAfterSend(forwardToThread(100), account: "account-2") == [historyRead(300) as Data],
          "Forward threads cannot publish another account's discussion reads")
    check(TLParser.pendingGhostReadsAfterSend(forwardToThread(100, scheduled: true), account: testAccount).isEmpty,
          "Scheduled forwards cannot publish reads")
    check(TLParser.pendingGhostReadsAfterSend(send(other), account: testAccount).isEmpty, "Never release another chat's reads")
    check(TLParser.pendingGhostReadsAfterSend(send(), account: nil).isEmpty, "Unknown accounts cannot publish reads")
    check(TLParser.pendingGhostReadsAfterSend(send(scheduled: true), account: testAccount).isEmpty, "Scheduled sends cannot publish reads")
    TLParser.acknowledgeGhostRead(historyRead(100), account: testAccount)
    check(TLParser.pendingGhostReadsAfterSend(send(), account: testAccount).count == 1, "Old acknowledgements cannot discard newer reads")
    TLParser.acknowledgeGhostRead(historyRead(200), account: testAccount)
    check(TLParser.pendingGhostReadsAfterSend(send(), account: testAccount).isEmpty, "Successful acknowledgements remove delivered reads")
    check(TLParser.pendingGhostReadsAfterSend(send(), account: "account-2") == [historyRead(300) as Data], "Read queues remain account-scoped")
    TLParser.noteBlockedRead(secretRead, account: testAccount)
    let encryptedSend = featureRequest(.messagesSendEncrypted, ["flags": Int32(0), "peer": secret, "randomId": Int64(1), "data": Buffer(data: Data([1]))])
    check(TLParser.pendingGhostReadsAfterSend(encryptedSend, account: testAccount) == [secretRead as Data], "Secret replies use an independent namespace")
    defaults.set(false, forKey: "TGExtraGhostReadOnReply")
    check(TLParser.pendingGhostReadsAfterSend(send(), account: "account-2").isEmpty, "Disabling read-on-reply discards pending reads")

    defaults.set(true, forKey: "TGExtraGhostKeepVoiceUnread")
    let voice = Api.DocumentAttribute.documentAttributeAudio(.init(flags: 1 << 10, duration: 3, title: nil, performer: nil, waveform: nil))
    let round = TLRecord(type: "DocumentAttribute", constructor: "documentAttributeVideo")
    round.fields = ["flags": Int32(1), "duration": Double(3), "w": Int32(100), "h": Int32(100)]
    func documentMedia(_ attributes: [TLRecord]) -> Api.MessageMedia {
        let document = TLRecord(type: "Document", constructor: "document")
        document.fields = ["flags": Int32(0), "id": Int64(1), "accessHash": Int64(2), "fileReference": Buffer(),
            "date": Int32(100), "mimeType": "audio/mp4", "size": Int64(10), "dcId": Int32(1), "attributes": attributes]
        let media = TLRecord(type: "MessageMedia", constructor: "messageMediaDocument")
        media.fields = ["flags": Int32(1), "document": document]
        return Api.MessageMedia(media)!
    }
    for (id, media) in [(Int32(98100), documentMedia([voice.record])), (98101, documentMedia([round])), (98102, documentMedia([]))] {
        _ = strip(serialized(message(id, media: media)))
    }
    let reads = featureRequest(.messagesReadContents, ["id": [Int32(98100), 98101, 98102]])
    check(TLParser.readMessageContentsPolicy(reads, account: testAccount)?["payload"] == featureRequest(.messagesReadContents, ["id": [Int32(98102)]]), "Playback privacy filters voice and rounds but permits known ordinary media")
    TGExtraTestSetGhostException(42, true)
    check(TLParser.readMessageContentsPolicy(reads, account: testAccount) == nil, "Playback privacy respects exceptions")
    TGExtraTestSetGhostException(42, false)
    let unknownDocument = TLRecord(type: "MessageMedia", constructor: "messageMediaDocument")
    unknownDocument["flags"] = Int32(0)
    _ = strip(serialized(message(98102, media: Api.MessageMedia(unknownDocument)!)))
    check(TLParser.readMessageContentsPolicy(featureRequest(.messagesReadContents, ["id": [Int32(98102)]]), account: testAccount)?["response"] != nil,
          "Unknown replacement media cannot inherit an old non-playable classification")
    defaults.set(false, forKey: "TGExtraGhostKeepVoiceUnread")

    flags("TGExtraAntiRevoke", "TGExtraAntiEdit")
    _ = patch(message(98200, text: "Deleted text")); _ = patch(deletion([98200]))
    let events = TLParser.messageLogEntries()
    check(events.count == 1 && events[0]["text"] as? String == "Deleted text" && (events[0]["peer"] as? NSNumber)?.int64Value == 42, "Deletion logs resolve snapshots before their disk flush")
    let detected = events[0]["date"] as! TimeInterval
    _ = patch(deletion([98200]))
    check(TLParser.messageLogEntries().count == 1 && TLParser.messageLogEntries()[0]["date"] as? TimeInterval == detected, "Duplicate deletions keep the first detection time")
    _ = patch(message(98201, text: "Original")); _ = patch(message(98201, text: "Edited", edit: 200))
    check(TLParser.messageLogEntries().count == 2, "Journal includes edits")
    _ = patch(message(98220, peer: .peerChannel(.init(channelId: 77)), text: "Purged channel message"))
    _ = patch(Api.Update.updateChannelAvailableMessages(.init(channelId: 77, availableMinId: 98220)))
    check(TLParser.messageLogEntries().contains { ($0["id"] as? NSNumber)?.int32Value == 98220 && $0["text"] as? String == "Purged channel message" },
          "Channel history pruning records known deleted messages too")
    check(TLParser.clearMessageLog() && TLParser.messageLogEntries().isEmpty && isDeleted(98200, peer: 42), "Clearing the journal preserves retained messages")

    defaults.set(true, forKey: "TGExtraSaveDeletedStories")
    let expiry = Int32(Date().timeIntervalSince1970 + 3600)
    func story(_ id: Int32, expires: Int32? = nil) -> TLRecord {
        let record = TLRecord(type: "StoryItem", constructor: "storyItem")
        record.fields = ["flags": Int32(3), "id": id, "date": expiry - 7200, "expireDate": expires ?? expiry, "caption": "Caption",
            "entities": [Api.MessageEntity.messageEntityBold(.init(offset: 0, length: 7)).record], "media": Api.MessageMedia.messageMediaEmpty.record]
        return record
    }
    let storyPeer = Api.Peer.peerUser(.init(userId: 42)).record
    func storyList(_ stories: [TLRecord]) -> NSData {
        let list = TLRecord(type: "PeerStories", constructor: "peerStories")
        list.fields = ["flags": Int32(0), "peer": storyPeer, "stories": stories]
        return list.serializedData()! as NSData
    }
    _ = strip(storyList([story(1), story(2), story(3, expires: expiry - 8000)]))
    let emptyList = storyList([])
    let restored = featureRecord(strip(emptyList)!)
    let stories = restored["stories"] as! [TLRecord]
    check(stories.count == 2 && (stories[0]["caption"] as? String)?.hasPrefix("🗑️ ") == true, "Full story lists restore only unexpired cached stories")
    check(((stories[0]["entities"] as! [TLRecord])[0]["offset"] as? Int32) == Int32("🗑️ ".utf16.count), "Deletion marks preserve caption formatting offsets")
    check(strip(emptyList, account: "account-2") == nil, "Story recovery never crosses accounts")
    let deleted = TLRecord(type: "StoryItem", constructor: "storyItemDeleted"); deleted["id"] = Int32(1)
    let update = TLRecord(type: "Update", constructor: "updateStory"); update.fields = ["peer": storyPeer, "story": deleted]
    check(strip(update.serializedData()! as NSData) != nil, "Live story deletions restore cached bodies")
    let request = featureRequest(.storiesGetByID, ["peer": peer, "id": [Int32(1)]])
    let byId = TLRecord(type: "stories.Stories", constructor: "stories")
    byId.fields = ["flags": Int32(0), "count": Int32(0), "stories": [TLRecord](), "chats": [TLRecord](), "users": [TLRecord]()]
    let recovered = TLParser.handleResponse(byId.serializedData()! as NSData, functionID: NSNumber(value: TLMethodID.storiesGetByID.id!), account: testAccount, requestPayload: request)!
    check((featureRecord(recovered)["stories"] as! [TLRecord]).count == 1, "ID lookups restore only requested stories")
    TLParser.clearStoryCache()
    check(strip(emptyList) != nil, "Story cache reloads from SQLite")
    defaults.set(false, forKey: "TGExtraSaveDeletedStories")
    check(strip(emptyList) == nil, "Disabling story protection stops recovery")
    TLParser.clearMessageData(); defaults.set(true, forKey: "TGExtraSaveDeletedStories")
    check(strip(emptyList) == nil, "Message clearing removes the story archive")

    defaults.set(true, forKey: "TGExtraForwardDropAuthor")
    let forward = featureRequest(.messagesForward, ["flags": Int32(0), "fromPeer": peer, "id": [Int32(1)], "randomId": [Int64(123)], "toPeer": other])
    let dropped = TLParser.rewriteRequestPayload(forward)!
    check((TLParser.request(dropped)!["flags"] as! Int32) & (1 << 11) != 0, "Forwarding sets drop_author")
    check(TLParser.rewriteRequestPayload(dropped) == nil, "Author removal is idempotent")
    defaults.set(false, forKey: "TGExtraForwardDropAuthor")
    check(TLParser.rewriteRequestPayload(forward) == nil, "Author removal is opt-in")
    flags(); defaults.set(true, forKey: "TGExtraAudioToVoice")
    TLParser.registerVoiceUpload(withFileName: "TGExtraAudio-test.m4a", duration: 4, waveform: nil)
    let file = Api.InputFile.inputFile(.init(id: 1, parts: 1, name: "TGExtraAudio-test.m4a", md5Checksum: ""))
    let media = Api.InputMedia.inputMediaUploadedDocument(.init(flags: 16, file: file, thumb: nil, mimeType: "audio/mp4",
        attributes: [.documentAttributeFilename(.init(fileName: "TGExtraAudio-test.m4a"))], stickers: nil, videoCover: nil, videoTimestamp: nil, ttlSeconds: nil))
    check(TLParser.voiceMedia(from: media) != nil, "File-to-voice works independently of video conversion")
    defaults.set(false, forKey: "TGExtraAudioToVoice")
    check(TLParser.voiceMedia(from: media) == nil, "Disabling file-to-voice preserves ordinary uploads")
    defaults.set(true, forKey: "TGExtraAudioToVoice")
    let batchNames = (0..<33).map { "TGExtraAudio-batch-\($0).m4a" }
    let waveform = Data([1, 2, 3])
    for (index, name) in batchNames.enumerated() {
        TLParser.registerVoiceUpload(withFileName: name, duration: index + 1, waveform: waveform as NSData)
    }
    func batchUpload(_ index: Int) -> NSData {
        let name = batchNames[index]
        let file = Api.InputFile.inputFile(.init(id: Int64(index + 1), parts: 1, name: name, md5Checksum: ""))
        let media = Api.InputMedia.inputMediaUploadedDocument(.init(flags: 16, file: file, thumb: nil, mimeType: "audio/mp4",
            attributes: [.documentAttributeFilename(.init(fileName: name))], stickers: nil, videoCover: nil, videoTimestamp: nil, ttlSeconds: nil))
        return featureRequest(.messagesSendMedia, ["flags": Int32(0), "peer": peer, "media": media.record,
            "message": "", "randomId": Int64(index + 1)])
    }
    for index in Array(batchNames.indices) + [0] {
        let payload = batchUpload(index)
        guard let rewritten = TLParser.rewriteRequestPayload(payload),
              let media = TLParser.request(rewritten)?["media"] as? TLRecord,
              let attributes = media["attributes"] as? [TLRecord], attributes.count == 1 else {
            fatalError("Every audio in a batch larger than 32, including retries, must become voice")
        }
        let attribute = attributes[0]
        check(attribute.constructorName == "documentAttributeAudio" && (attribute["flags"] as? Int32 ?? 0) & (1 << 10) != 0 &&
              attribute["duration"] as? Int32 == Int32(index + 1), "Batch uploads preserve voice flags and each file's duration")
        check((attribute["waveform"] as? Buffer)?.makeData() == TLParser.packWaveform(waveform), "Batch uploads preserve waveforms")
        check((media["flags"] as? Int32 ?? 0) & 16 == 0, "Batch voices clear force_file")
    }
    print("PASS expanded Ghost Mode, read-on-reply isolation, playback privacy, event times, deleted stories, authorless forwards and audio uploads")
}
