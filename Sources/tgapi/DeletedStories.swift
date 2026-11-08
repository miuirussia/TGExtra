import Foundation

extension TLParser {
    static var requestedStoryPeer: Int64?
    static var requestedStoryIds: [Int32]?
    private static var storyCache = [MessageKey: Data]()
    private static var storyCacheLoaded = false

    static func clearStoryCache() {
        storyCache.removeAll()
        storyCacheLoaded = false
    }

    static func storyRequest(_ payload: NSData?) -> (Int64?, [Int32]?) {
        guard let payload = payload, let method = requestMethod(payload),
              [.storiesGetByID, .storiesGetPeerStories].contains(method),
              let record = request(payload), let input = record["peer"] as? TLRecord else { return (nil, nil) }
        let peer: Int64?
        switch input.constructorName {
        case "inputPeerUser", "inputPeerUserFromMessage": peer = input["userId"] as? Int64
        case "inputPeerChannel", "inputPeerChannelFromMessage":
            peer = (input["channelId"] as? Int64).flatMap { $0 > 0 && $0 < Int64.max - 1_000_000_000_000 ? -(1_000_000_000_000 + $0) : nil }
        case "inputPeerSelf": peer = processingHistoryAccount.flatMap { PeerInfoStore.ownUserId(for: $0)?.int64Value }
        default: peer = nil
        }
        return (peer, record["id"] as? [Int32])
    }

    private static func cachedStory(_ key: MessageKey) -> TLRecord? {
        guard let bytes = storyCache[key] else { return nil }
        let reader = BufferReader(Buffer(data: bytes))
        guard let signature = reader.readInt32(), let descriptor = TLCodec.descriptor(signature),
              let record = TLCodec.parse(reader, descriptor: descriptor), reader.remaining == 0,
              record.constructorName == "storyItem", let expiry = record["expireDate"] as? Int32,
              TimeInterval(expiry) > Date().timeIntervalSince1970 else {
            storyCache.removeValue(forKey: key)
            return nil
        }
        return record
    }

    private static func restoredStory(_ key: MessageKey) -> TLRecord? {
        guard let record = cachedStory(key) else { return nil }
        let prefix = "🗑️ "
        record["caption"] = prefix + (record["caption"] as? String ?? "")
        record["flags"] = (record["flags"] as? Int32 ?? 0) | 1
        for entity in record["entities"] as? [TLRecord] ?? [] {
            if let offset = entity["offset"] as? Int32, offset <= Int32.max - Int32(prefix.utf16.count) {
                entity["offset"] = offset + Int32(prefix.utf16.count)
            }
        }
        return record
    }

    // Called under processingLock, for both decoded wire objects and native objects.
    static func patchDeletedStories(_ root: TLRecord?, peer inheritedPeer: Int64? = nil, depth: Int = 0) -> Bool {
        guard packetSettings.saveDeletedStories, let account = processingHistoryAccount,
              let root = root, depth < 48 else { return false }
        if !storyCacheLoaded {
            storyCache = MessageHistoryArchive.shared.loadStories()
            storyCacheLoaded = true
        }
        var peer = inheritedPeer
        if let raw = root["peer"] as? TLRecord, raw.typeName == "Peer", let view = Api.Peer(raw) { peer = peerKey(view) }
        if root.typeName == "StoryItem" {
            guard root.constructorName == "storyItem", let peer = peer, peer != 0,
                  let id = root["id"] as? Int32, id > 0, let expiry = root["expireDate"] as? Int32,
                  TimeInterval(expiry) > Date().timeIntervalSince1970,
                  let bytes = root.serializedData(), bytes.count <= 512 * 1024 else { return false }
            let key = MessageKey(account: account, peer: peer, id: id)
            if storyCache[key] != bytes {
                storyCache[key] = bytes
                MessageHistoryArchive.shared.saveStory(bytes, key: key, expiry: expiry)
            }
            if storyCache.count > 600 || storyCache.values.reduce(0, { $0 + $1.count }) > 32 * 1024 * 1024 {
                for key in Array(storyCache.keys).sorted(by: { $0.storageKey < $1.storageKey }) {
                    guard storyCache.count > 600 || storyCache.values.reduce(0, { $0 + $1.count }) > 32 * 1024 * 1024 else { break }
                    storyCache.removeValue(forKey: key)
                }
            }
            return false
        }
        var changed = false
        for field in root.descriptor?.fields ?? [] {
            if field.kind == 6, let child = root[field.name] as? TLRecord {
                if child.constructorName == "storyItemDeleted", let peer = peer, let id = child["id"] as? Int32,
                   let restored = restoredStory(MessageKey(account: account, peer: peer, id: id)) {
                    root[field.name] = restored
                    changed = true
                } else if patchDeletedStories(child, peer: peer, depth: depth + 1) { changed = true }
            } else if field.kind == 7 && field.elementKind == 6, let children = root[field.name] as? [TLRecord] {
                var rewritten = children
                var vectorChanged = false
                for index in children.indices {
                    let child = children[index]
                    if child.constructorName == "storyItemDeleted", let peer = peer, let id = child["id"] as? Int32,
                       let restored = restoredStory(MessageKey(account: account, peer: peer, id: id)) {
                        rewritten[index] = restored
                        vectorChanged = true
                    } else if patchDeletedStories(child, peer: peer, depth: depth + 1) { changed = true }
                }
                // PeerStories is a full list; getStoriesByID may restore only requested IDs.
                if field.name == "stories", let peer = peer,
                   root.typeName == "PeerStories" || (root.typeName == "stories.Stories" && requestedStoryIds != nil) {
                    let present = Set(rewritten.compactMap { $0["id"] as? Int32 })
                    let candidates = Array(storyCache.keys).filter {
                        $0.account == account && $0.peer == peer && !present.contains($0.id)
                    }
                    for key in candidates.sorted(by: { $0.id < $1.id }) {
                        if let ids = requestedStoryIds, !ids.contains(key.id) { continue }
                        if let restored = restoredStory(key) { rewritten.append(restored); vectorChanged = true }
                    }
                    if vectorChanged { rewritten.sort { ($0["id"] as? Int32 ?? 0) < ($1["id"] as? Int32 ?? 0) } }
                }
                if vectorChanged {
                    root[field.name] = rewritten
                    if root.typeName == "stories.Stories", let count = root["count"] as? Int32 {
                        root["count"] = max(count, Int32(rewritten.count))
                    }
                    changed = true
                }
            }
        }
        return changed
    }
}
