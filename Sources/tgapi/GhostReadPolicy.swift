import Foundation

extension TLParser {
    private struct PendingReadKey: Hashable {
        let account: String
        let peer: String
        let method: TLMethodID
        let thread: Int32
    }
    private struct PendingRead {
        let payload: Data
        let maximum: Int32
        let sequence: UInt64
    }
    // In-memory only: restarting or disabling the mode must never publish old reads.
    private static var pendingReads = [PendingReadKey: PendingRead]()
    private static var pendingReadSequence: UInt64 = 0

    static func requestPeer(_ record: TLRecord) -> String? {
        guard let peer = (record["peer"] ?? record["toPeer"] ?? record["channel"]) as? TLRecord else { return nil }
        switch peer.constructorName {
        case "inputPeerUser", "inputPeerUserFromMessage": return (peer["userId"] as? Int64).map { "user:\($0)" }
        case "inputPeerChat": return (peer["chatId"] as? Int64).map { "chat:\($0)" }
        case "inputPeerChannel", "inputPeerChannelFromMessage", "inputChannel", "inputChannelFromMessage":
            return (peer["channelId"] as? Int64).map { "channel:\($0)" }
        case "inputEncryptedChat": return (peer["chatId"] as? Int32).map { "secret:\($0)" }
        default: return nil
        }
    }

    @objc static func clearPendingGhostReads() {
        processingLock.lock()
        defer { processingLock.unlock() }
        pendingReads.removeAll()
    }

    @objc(noteBlockedRead:account:) static func noteBlockedRead(_ payload: NSData, account: String?) {
        processingLock.lock()
        defer { processingLock.unlock() }
        guard UserDefaults.standard.bool(forKey: "TGExtraGhostModeEnabled"),
              UserDefaults.standard.bool(forKey: "TGExtraGhostReadOnReply") else {
            pendingReads.removeAll()
            return
        }
        guard let account = account, let method = requestMethod(payload),
              [.messagesReadHistory, .channelsReadHistory, .messagesReadDiscussion, .messagesReadEncryptedHistory].contains(method),
              fakeResponseForPayload(payload) != nil,
              let record = request(payload), let peer = requestPeer(record) else { return }
        let maximum = (record["readMaxId"] ?? record["maxId"] ?? record["maxDate"]) as? Int32 ?? 0
        let key = PendingReadKey(account: account, peer: peer, method: method, thread: record["msgId"] as? Int32 ?? 0)
        if let previous = pendingReads[key], previous.maximum >= maximum { return }
        pendingReadSequence &+= 1
        pendingReads[key] = PendingRead(payload: payload as Data, maximum: maximum, sequence: pendingReadSequence)
        if pendingReads.count > 512, let oldest = pendingReads.min(by: { $0.value.sequence < $1.value.sequence })?.key {
            pendingReads.removeValue(forKey: oldest)
        }
    }

    @objc(isGhostReplyPayload:) static func isGhostReplyPayload(_ payload: NSData) -> Bool {
        guard let method = requestMethod(payload),
              [.messagesSendMessage, .messagesSendMedia, .messagesSendMultiMedia, .messagesSendInlineBotResult,
               .messagesForward, .messagesSendEncrypted, .messagesSendEncryptedFile].contains(method),
              let record = request(payload), record["scheduleDate"] == nil, requestPeer(record) != nil else { return false }
        return true
    }

    @objc(pendingGhostReadsAfterSend:account:) static func pendingGhostReadsAfterSend(_ payload: NSData, account: String?) -> [Data] {
        processingLock.lock()
        defer { processingLock.unlock() }
        guard UserDefaults.standard.bool(forKey: "TGExtraGhostModeEnabled"),
              UserDefaults.standard.bool(forKey: "TGExtraGhostReadOnReply") else {
            pendingReads.removeAll()
            return []
        }
        guard let account = account, isGhostReplyPayload(payload), let record = request(payload),
              !exceptionPeer(record), let peer = requestPeer(record) else { return [] }
        let reply = record["replyTo"] as? TLRecord
        let thread = (record["topMsgId"] ?? reply?["topMsgId"] ?? reply?["replyToMsgId"]) as? Int32
        return pendingReads.filter {
            $0.key.account == account && $0.key.peer == peer &&
                ($0.key.method != .messagesReadDiscussion || $0.key.thread == thread)
        }
            .sorted { $0.value.sequence < $1.value.sequence }.map { $0.value.payload }
    }

    @objc(acknowledgeGhostRead:account:) static func acknowledgeGhostRead(_ payload: NSData, account: String?) {
        processingLock.lock()
        defer { processingLock.unlock() }
        guard let account = account else { return }
        for (key, pending) in pendingReads where key.account == account && pending.payload == payload as Data {
            pendingReads.removeValue(forKey: key)
        }
    }

    static func playableMedia(_ media: Api.MessageMedia?) -> Bool? {
        guard let media = media else { return false }
        guard media.record.constructorName == "messageMediaDocument" else { return false }
        guard let document = media.record["document"] as? TLRecord, document.constructorName == "document",
              let attributes = document["attributes"] as? [TLRecord] else { return nil }
        return attributes.contains {
            let flags = $0["flags"] as? Int32 ?? 0
            return ($0.constructorName == "documentAttributeAudio" && flags & (1 << 10) != 0) ||
                ($0.constructorName == "documentAttributeVideo" && flags & 1 != 0)
        }
    }
}
