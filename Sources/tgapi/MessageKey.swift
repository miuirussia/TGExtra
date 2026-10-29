import Foundation

struct MessageKey: Hashable {
    let account: String
    let peer: Int64
    let id: Int32
    let namespace: Int32

    var storageKey: String {
        let base = "\(account):\(peer):\(id)"
        return namespace == 0 ? base : "\(base):\(namespace)"
    }

    init(account: String, peer: Int64, id: Int32, namespace: Int32 = 0) {
        self.account = account
        self.peer = peer
        self.id = id
        self.namespace = namespace
    }

    init?(storageKey: String) {
        let parts = storageKey.split(separator: ":")
        guard parts.count == 3 || parts.count == 4,
              let peer = Int64(parts[1]), let id = Int32(parts[2]) else { return nil }
        self.account = String(parts[0])
        self.peer = peer
        self.id = id
        if parts.count == 4 {
            guard let namespace = Int32(parts[3]) else { return nil }
            self.namespace = namespace
        } else { self.namespace = 0 }
    }
}

