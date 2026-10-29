import Foundation

extension TLParser {
    static let cloudScope: Int64 = 0

    static let markerUdKey = "TGExtraMessageMarkersByAccount"

    // Access requires processingLock.
    static var messageMarkers = [MessageKey: Int]()

    static var markersLoaded = false

    static var markersDirty = false

    static var dirtyMarkers = Set<MessageKey>()

    static var markerBatchDepth = 0

    static let deletedMarker = 1

    static let disappearingMarker = 2

    static let autoDeleteMarker = 4

    static func loadMarkers() {
        guard !markersLoaded, prepareMessageArchive() else { return }
        messageMarkers = MessageHistoryArchive.shared.loadMarkers()
        markersLoaded = true
    }

    static func markerKey(id: Int32, peer: Int64, account: String?, namespace: Int32) -> MessageKey? {
        guard id != 0, let account = account else { return nil }
        let scope = (namespace == 0 || namespace == 5) && peer > -1_000_000_000_000 ? cloudScope : peer
        return MessageKey(account: account, peer: scope, id: id, namespace: namespace)
    }

    static func markerBits(id: Int32, peer: Int64, account: String?, namespace: Int32) -> Int {
        loadMarkers()
        guard let key = markerKey(id: id, peer: peer, account: account, namespace: namespace) else { return 0 }
        var bits = messageMarkers[key] ?? 0
        if namespace == 0 && peer <= -1_000_000_000_000 {
            let range = MessageKey(account: key.account, peer: peer, id: 0)
            if id > 0 && Int(id) <= messageMarkers[range, default: 0] { bits |= deletedMarker }
        }
        return bits
    }

    static func persistMarkers(_ key: MessageKey) {
        markersDirty = true
        dirtyMarkers.insert(key)
        if markerBatchDepth == 0 { flushMarkers() }
    }

    static func flushMarkers() {
        guard markersDirty || snapshotFlushRequested else { return }
        flushMessageData()
    }

    static func recordMarker(_ bit: Int, id: Int32, peer: Int64, account: String?, namespace: Int32) {
        loadMarkers()
        guard markersLoaded, let key = markerKey(id: id, peer: peer, account: account, namespace: namespace),
              (messageMarkers[key, default: 0] & bit) == 0 else { return }
        messageMarkers[key, default: 0] |= bit
        if bit & deletedMarker != 0 { pinSnapshots(for: key) }
        persistMarkers(key)
    }

    @objc(addDeletedId:peer:account:messageNamespace:) static func addDeletedId(_ id: Int32, peer: Int64, account: String?, namespace: Int32 = 0) {
        processingLock.lock()
        defer { processingLock.unlock() }
        recordMarker(deletedMarker, id: id, peer: peer, account: account, namespace: namespace)
    }
}
