import Foundation

@objc(TGExtraPeerInfoStore)
final class PeerInfoStore: NSObject {
    private static let ownUserIdsKey = "TGExtraOwnUserIdsByAccount"
    private static let ownIdLock = NSLock()

    static func ownUserId(for account: String) -> NSNumber? {
        ownIdLock.lock()
        defer { ownIdLock.unlock() }
        return UserDefaults.standard.dictionary(forKey: ownUserIdsKey)?[account] as? NSNumber
    }

    static func rememberOwnUserId(_ id: Int64, account: String) {
        ownIdLock.lock()
        defer { ownIdLock.unlock() }
        var saved = UserDefaults.standard.dictionary(forKey: ownUserIdsKey) ?? [:]
        guard (saved[account] as? NSNumber)?.int64Value != id else { return }
        saved[account] = NSNumber(value: id)
        UserDefaults.standard.set(saved, forKey: ownUserIdsKey)
    }

    static func observe(_ users: [Api.User], account: String?) {
        if let account = account {
            for case let .user(data) in users where data.flags & (1 << 10) != 0 {
                rememberOwnUserId(data.id, account: account)
                break
            }
        }
        notePeerNames(in: users)
    }

    private static let peerNameQueue = DispatchQueue(label: "com.tgextra.peerNames",
                                                     attributes: .concurrent)
    private static var _peerNames = [Int64: [String: String]]()

    private static func notePeerNames(in users: [Api.User]) {
        var batch = [Int64: [String: String]]()
        for user in users {
            guard case let .user(data) = user else { continue }
            var info = [String: String]()
            let name = [data.firstName, data.lastName]
                .compactMap { $0 }
                .filter { !$0.isEmpty }
                .joined(separator: " ")
            if !name.isEmpty { info["name"] = name }
            if let username = data.username, !username.isEmpty {
                info["username"] = username
            } else if let extra = data.usernames {
                for case let .username(entry) in extra where !entry.username.isEmpty {
                    info["username"] = entry.username
                    break
                }
            }
            guard !info.isEmpty else { continue }
            batch[data.id] = info
        }
        guard !batch.isEmpty else { return }
        peerNameQueue.async(flags: .barrier) {
            for (id, info) in batch { _peerNames[id] = info }
            if _peerNames.count > 2000 { _peerNames.removeAll(keepingCapacity: true) }
        }
    }

    @objc(cachedPeerInfoForId:) static func cachedPeerInfo(forId id: NSNumber) -> [String: String]? {
        var result: [String: String]?
        peerNameQueue.sync { result = _peerNames[id.int64Value] }
        return result
    }
}
