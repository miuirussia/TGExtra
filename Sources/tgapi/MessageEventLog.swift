import Foundation

extension TLParser {
    static func logDeletion(id: Int32, peer: Int64, account: String, namespace: Int32) {
        let marker = MessageKey(account: account, peer: peer, id: id, namespace: namespace)
        var key = marker
        var text = ""
        if namespace == 0 {
            let matches = MessageHistoryArchive.shared.snapshots(account: account, id: id, peer: peer == cloudScope ? nil : peer)
            var candidates = Dictionary(uniqueKeysWithValues: matches.map { ($0.key, $0.bytes) })
            for cached in snapshotKeysByMarker[marker] ?? [] {
                if let bytes = snapshots[cached] { candidates[cached] = bytes }
            }
            if candidates.count == 1, let (source, bytes) = candidates.first {
                key = source
                if case let .message(data)? = decodedSnapshot(bytes) { text = data.message }
            }
            if text.isEmpty, peer != 0, let bytes = snapshots[key], case let .message(data)? = decodedSnapshot(bytes) {
                text = data.message
            }
        }
        let now = Date().timeIntervalSince1970
        var event: [String: Any] = ["kind": "deleted", "account": account, "peer": key.peer,
            "id": id, "namespace": namespace, "text": text, "date": now]
        if key.peer > 0 { event["name"] = PeerInfoStore.cachedPeerInfo(forId: NSNumber(value: key.peer))?["name"] }
        MessageHistoryArchive.shared.saveEvent(event,
            identifier: "deleted:\(marker.storageKey)", date: now)
        notifyEventLogChanged()
    }

    static func notifyEventLogChanged() {
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: NSNotification.Name("TGExtraMessageLogChanged"), object: nil)
        }
    }

    @objc static func messageLogEntries() -> [[String: Any]] {
        MessageHistoryArchive.shared.eventEntries().map { entry in
            var value = entry
            if let account = entry["account"] as? String, let own = PeerInfoStore.ownUserId(for: account) {
                value["accountName"] = PeerInfoStore.cachedPeerInfo(forId: own)?["name"] ?? own.stringValue
            }
            if let peer = entry["peer"] as? NSNumber, peer.int64Value > 0,
               let name = PeerInfoStore.cachedPeerInfo(forId: peer)?["name"] {
                value["name"] = name
            }
            return value
        }
    }

    @objc static func clearMessageLog() -> Bool {
        let cleared = MessageHistoryArchive.shared.clearEvents()
        if cleared { notifyEventLogChanged() }
        return cleared
    }
}
