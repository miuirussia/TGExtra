import Foundation

@objc(TLParser)
class TLParser: NSObject {
    @objc static func loadPersistedIds() {
        processingLock.lock()
        loadMarkers()
        processingLock.unlock()
        editHistoryStore.load()
        installApiLogger()
    }


    @discardableResult
    @objc static func clearMessageData() -> Bool {
        processingLock.lock()
        defer { processingLock.unlock() }
        guard editHistoryStore.clear() else { return false }
        snapshotsLoaded = true
        snapshots.removeAll()
        snapshotOrder.removeAll()
        snapshotGeneration &+= 1
        snapshotWriteScheduled = false
        UserDefaults.standard.removeObject(forKey: snapshotUdKey)
        markersLoaded = true
        messageMarkers.removeAll()
        markersDirty = false
        contentReadStates.removeAll()
        contentReadOrder.removeAll()
        for key in [markerUdKey, "TGExtraDeletedMsgIds", "TGExtraSelfDestructingMsgIds", "TGExtraAutoDeleteMsgIds"] {
            UserDefaults.standard.removeObject(forKey: key)
        }
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: NSNotification.Name("TGExtraMessageDataCleared"), object: nil)
        }
        return true
    }

    static func peerKey(_ peer: Api.Peer) -> Int64 {
        switch peer {
        case let .peerUser(data): return data.userId
        case let .peerChat(data): return -data.chatId
        case let .peerChannel(data): return -(1_000_000_000_000 + data.channelId)
        case .other: return 0
        }
    }

    @objc(editHistoryForId:peer:account:messageNamespace:) static func editHistory(forId id: NSNumber, peer: NSNumber?, account: String?, namespace: NSNumber? = nil) -> [String]? {
        guard let account = account, let peer = peer, peer.int64Value != 0 else { return nil }
        let key = MessageKey(account: account, peer: peer.int64Value, id: id.int32Value, namespace: namespace?.int32Value ?? 0)
        return editHistoryStore.versions(for: key)
    }

    @objc(editRevisionDetailsForId:peer:account:messageNamespace:) static func editRevisionDetails(forId id: NSNumber, peer: NSNumber?, account: String?, namespace: NSNumber?) -> [[String: Any]]? {
        guard let account = account, let peer = peer else { return nil }
        let key = MessageKey(account: account, peer: peer.int64Value, id: id.int32Value, namespace: namespace?.int32Value ?? 0)
        return editHistoryStore.details(for: key)
    }

    static var isOwnIdKnown: Bool {
        guard let account = processingHistoryAccount else { return true }
        return PeerInfoStore.ownUserId(for: account) != nil
    }

    static func noteUsersAnywhere(_ result: Any) {
        guard let record = Api.record(result) else { return }
        if let values = record["users"] as? [TLRecord] {
            let users = values.compactMap(Api.User.init)
            PeerInfoStore.observe(users, account: processingHistoryAccount)
        } else if let user = Api.User(record) {
            PeerInfoStore.observe([user], account: processingHistoryAccount)
        }
    }

    @objc(isDeleted:peer:account:messageNamespace:) static func isDeleted(_ msgId: NSNumber, peer: NSNumber?, account: String?, namespace: NSNumber? = nil) -> Bool {
        guard let peer = peer, peer.int64Value != 0 else { return false }
        processingLock.lock()
        defer { processingLock.unlock() }
        return markerBits(id: msgId.int32Value, peer: peer.int64Value, account: account,
                          namespace: namespace?.int32Value ?? 0) & deletedMarker != 0
    }

    @objc(isMessageSelfDestructing:peer:account:messageNamespace:) static func isMessageSelfDestructing(_ msgId: NSNumber, peer: NSNumber?, account: String?, namespace: NSNumber? = nil) -> Bool {
        guard let peer = peer else { return false }
        processingLock.lock()
        defer { processingLock.unlock() }
        return markerBits(id: msgId.int32Value, peer: peer.int64Value, account: account,
                          namespace: namespace?.int32Value ?? 0) & disappearingMarker != 0
    }

    static func serializeBoxed(_ obj: Any) -> NSData {
        let outBuf = Buffer()
        Api.serializeObject(obj, buffer: outBuf, boxed: true)
        return outBuf.makeData() as NSData
    }
}
