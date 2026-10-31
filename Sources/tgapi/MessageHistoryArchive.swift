import Foundation
import SQLite3

struct MessageSnapshotRow {
    let key: MessageKey
    let bytes: Data
    let position: Int64
}

final class MessageHistoryArchive {
    static let shared = MessageHistoryArchive(path: defaultPath)
    private static var defaultPath: String {
#if TGEXTRA_TESTING
        return ProcessInfo.processInfo.environment["TGEXTRA_TEST_HISTORY_PATH"] ?? ":memory:"
#else
        return NSHomeDirectory() + "/Library/Application Support/TGExtra/History.sqlite"
#endif
    }

    // All statements, pending changes and disk access belong to this queue.
    private let queue = DispatchQueue(label: "TGExtra.HistoryArchive", qos: .utility)
    private let path: String
    private var database: OpaquePointer?
    private var statements = [String: OpaquePointer]()
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    private var pendingRevisions = [String: [String: Any]]()
    private var removedRevisions = Set<String>()
    private var pendingSnapshots = [MessageKey: MessageSnapshotRow]()
    private var removedSnapshots = Set<MessageKey>()
    private var pendingMarkers = [MessageKey: Int]()
    private var flushScheduled = false
#if TGEXTRA_TESTING
    private var commits = 0
#endif

    init(path: String) { self.path = path }
    deinit {
        for statement in statements.values { sqlite3_finalize(statement) }
        if let database = database { sqlite3_close(database) }
    }

    private func open() -> Bool {
        if database != nil { return true }
        do {
            if path != ":memory:" {
                try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent,
                                                        withIntermediateDirectories: true)
            }
        } catch { NSLog("[TGExtra] History directory: %@", error.localizedDescription); return false }
        var handle: OpaquePointer?
        guard sqlite3_open_v2(path, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK,
              let handle = handle else {
            if let handle = handle { sqlite3_close(handle) }
            NSLog("[TGExtra] Cannot open history archive")
            return false
        }
        sqlite3_busy_timeout(handle, 5000)
        database = handle
        guard execute("PRAGMA journal_mode=WAL"), execute("PRAGMA synchronous=FULL"),
              execute("CREATE TABLE IF NOT EXISTS revisions (key TEXT PRIMARY KEY, value BLOB NOT NULL)"),
              execute("CREATE TABLE IF NOT EXISTS snapshots (key TEXT PRIMARY KEY, value BLOB NOT NULL, position INTEGER NOT NULL)"),
              execute("CREATE TABLE IF NOT EXISTS markers (key TEXT PRIMARY KEY, value INTEGER NOT NULL)"),
              execute("CREATE TABLE IF NOT EXISTS message_data_migration (value INTEGER NOT NULL)") else {
            sqlite3_close(handle)
            database = nil
            return false
        }
        return true
    }

    private func execute(_ sql: String) -> Bool {
        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else { reportError(); return false }
        return true
    }

    private func reportError() { NSLog("[TGExtra] History archive: %s", sqlite3_errmsg(database)) }

    private func statement(_ sql: String) -> OpaquePointer? {
        if let cached = statements[sql] { return cached }
        var value: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &value, nil) == SQLITE_OK, let value = value else {
            reportError(); return nil
        }
        statements[sql] = value
        return value
    }

    private func mutate(_ sql: String, key: String, data: Data? = nil, integer: Int64? = nil) -> Bool {
        guard let statement = statement(sql) else { return false }
        defer { sqlite3_reset(statement); sqlite3_clear_bindings(statement) }
        guard sqlite3_bind_text(statement, 1, key, -1, transient) == SQLITE_OK else { reportError(); return false }
        if let data = data {
            let status = data.isEmpty ? sqlite3_bind_zeroblob(statement, 2, 0) : data.withUnsafeBytes {
                sqlite3_bind_blob(statement, 2, $0.baseAddress, Int32($0.count), transient)
            }
            guard status == SQLITE_OK else { reportError(); return false }
        }
        if let integer = integer {
            guard sqlite3_bind_int64(statement, data == nil ? 2 : 3, integer) == SQLITE_OK else { reportError(); return false }
        }
        guard sqlite3_step(statement) == SQLITE_DONE else { reportError(); return false }
        return true
    }

    private func write(_ value: [String: Any], key: String, preserveExisting: Bool = false) -> Bool {
        guard let data = try? PropertyListSerialization.data(fromPropertyList: value, format: .binary, options: 0) else { return false }
        return mutate(preserveExisting ? "INSERT OR IGNORE INTO revisions VALUES (?, ?)" : "INSERT OR REPLACE INTO revisions VALUES (?, ?)",
                      key: key, data: data)
    }

    private func scalar(_ sql: String) -> Int32? {
        guard let statement = statement(sql) else { return nil }
        defer { sqlite3_reset(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { reportError(); return nil }
        return sqlite3_column_int(statement, 0)
    }

    func migrate(_ legacy: [String: [String: Any]]) -> Bool {
        queue.sync {
            guard open(), flushPending(), let version = scalar("PRAGMA user_version") else { return false }
            if version >= 1 { return true }
            guard execute("BEGIN IMMEDIATE") else { return false }
            for (key, value) in legacy where MessageKey(storageKey: key) != nil {
                guard write(value, key: key, preserveExisting: true) else { _ = execute("ROLLBACK"); return false }
            }
            guard execute("PRAGMA user_version=1"), execute("COMMIT") else { _ = execute("ROLLBACK"); return false }
            return true
        }
    }

    func migrateMessageData(snapshots: [String: Any], markers: [String: Any]) -> Bool {
        queue.sync {
            guard open(), flushPending(), let migrated = scalar("SELECT COUNT(*) FROM message_data_migration") else { return false }
            if migrated != 0 { return true }
            guard execute("BEGIN IMMEDIATE") else { return false }
            let messages = snapshots["messages"] as? [String: Data] ?? [:]
            let order = snapshots["order"] as? [String] ?? []
            var seen = Set<String>()
            let keys = order.filter { messages[$0] != nil && seen.insert($0).inserted } + messages.keys.filter { !seen.contains($0) }.sorted()
            for (position, key) in keys.enumerated() where MessageKey(storageKey: key) != nil {
                guard mutate("INSERT OR IGNORE INTO snapshots VALUES (?, ?, ?)", key: key,
                             data: messages[key], integer: Int64(position)) else { _ = execute("ROLLBACK"); return false }
            }
            for (key, raw) in markers where MessageKey(storageKey: key) != nil {
                guard let value = raw as? NSNumber else { continue }
                guard mutate("INSERT OR IGNORE INTO markers VALUES (?, ?)", key: key, integer: value.int64Value) else {
                    _ = execute("ROLLBACK"); return false
                }
            }
            guard execute("INSERT INTO message_data_migration VALUES (1)"), execute("COMMIT") else {
                _ = execute("ROLLBACK"); return false
            }
            return true
        }
    }

    func load() -> [String: [String: Any]] {
        queue.sync {
            guard open(), flushPending(), let statement = statement("SELECT key, value FROM revisions") else { return [:] }
            defer { sqlite3_reset(statement) }
            var result = [String: [String: Any]]()
            var status = sqlite3_step(statement)
            while status == SQLITE_ROW {
                if let key = sqlite3_column_text(statement, 0), let bytes = sqlite3_column_blob(statement, 1) {
                    let data = Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, 1)))
                    if let value = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any] {
                        result[String(cString: key)] = value
                    }
                }
                status = sqlite3_step(statement)
            }
            if status != SQLITE_DONE { reportError() }
            return result
        }
    }

    func revision(for key: MessageKey) -> [String: Any]? {
        queue.sync {
            if removedRevisions.contains(key.storageKey) { return nil }
            if let value = pendingRevisions[key.storageKey] { return value }
            guard open(), let statement = statement("SELECT value FROM revisions WHERE key = ?") else { return nil }
            defer { sqlite3_reset(statement); sqlite3_clear_bindings(statement) }
            guard sqlite3_bind_text(statement, 1, key.storageKey, -1, transient) == SQLITE_OK,
                  sqlite3_step(statement) == SQLITE_ROW,
                  let bytes = sqlite3_column_blob(statement, 0) else { return nil }
            let data = Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, 0)))
            return (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any]
        }
    }

    func originalKeys() -> [MessageKey] {
        queue.sync {
            guard open(), flushPending(), let statement = statement("SELECT key, value FROM revisions") else { return [] }
            defer { sqlite3_reset(statement) }
            var keys = [MessageKey]()
            while sqlite3_step(statement) == SQLITE_ROW {
                autoreleasepool {
                    guard let raw = sqlite3_column_text(statement, 0), let key = MessageKey(storageKey: String(cString: raw)),
                          let bytes = sqlite3_column_blob(statement, 1) else { return }
                    let data = Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, 1)))
                    let value = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any]
                    if (value?["versions"] as? [String])?.count == 1 { keys.append(key) }
                }
            }
            return keys
        }
    }

    func visitSnapshotKeys(_ visit: (MessageKey, Int64) -> Void) {
        queue.sync {
            guard open(), flushPending(), let statement = statement("SELECT key, position FROM snapshots ORDER BY position, key") else { return }
            defer { sqlite3_reset(statement) }
            while sqlite3_step(statement) == SQLITE_ROW {
                if let raw = sqlite3_column_text(statement, 0), let key = MessageKey(storageKey: String(cString: raw)) {
                    visit(key, sqlite3_column_int64(statement, 1))
                }
            }
        }
    }

    func loadSnapshots(limit: Int? = nil) -> [MessageSnapshotRow] {
        queue.sync {
            let sql = limit.map { "SELECT key, value, position FROM (SELECT * FROM snapshots ORDER BY position DESC, key DESC LIMIT \(max(0, $0))) ORDER BY position, key" }
                ?? "SELECT key, value, position FROM snapshots ORDER BY position, key"
            guard open(), flushPending(), let statement = statement(sql) else { return [] }
            defer { sqlite3_reset(statement) }
            var result = [MessageSnapshotRow]()
            var status = sqlite3_step(statement)
            while status == SQLITE_ROW {
                if let raw = sqlite3_column_text(statement, 0), let key = MessageKey(storageKey: String(cString: raw)),
                   let bytes = sqlite3_column_blob(statement, 1) {
                    result.append(MessageSnapshotRow(key: key, bytes: Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, 1))),
                                                     position: sqlite3_column_int64(statement, 2)))
                }
                status = sqlite3_step(statement)
            }
            if status != SQLITE_DONE { reportError() }
            return result
        }
    }

    func snapshots(account: String, id: Int32, peer: Int64?) -> [MessageSnapshotRow] {
        queue.sync {
            guard open() else { return [] }
            let sql = peer == nil ? "SELECT key, value, position FROM snapshots WHERE key LIKE ? ESCAPE '\\'" :
                "SELECT key, value, position FROM snapshots WHERE key = ?"
            guard let statement = statement(sql) else { return [] }
            defer { sqlite3_reset(statement); sqlite3_clear_bindings(statement) }
            let escaped = account.replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "%", with: "\\%").replacingOccurrences(of: "_", with: "\\_")
            let pattern = peer.map { MessageKey(account: account, peer: $0, id: id).storageKey } ?? "\(escaped):%:\(id)"
            guard sqlite3_bind_text(statement, 1, pattern, -1, transient) == SQLITE_OK else { return [] }
            var result = [MessageKey: MessageSnapshotRow]()
            while sqlite3_step(statement) == SQLITE_ROW {
                if let raw = sqlite3_column_text(statement, 0), let key = MessageKey(storageKey: String(cString: raw)),
                   let bytes = sqlite3_column_blob(statement, 1), !removedSnapshots.contains(key),
                   key.account == account, key.id == id, key.namespace == 0,
                   peer != nil || key.peer > -1_000_000_000_000 {
                    result[key] = MessageSnapshotRow(key: key, bytes: Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, 1))),
                                                     position: sqlite3_column_int64(statement, 2))
                }
            }
            for (key, row) in pendingSnapshots where key.account == account && key.id == id && key.namespace == 0 &&
                (peer.map { key.peer == $0 } ?? (key.peer > -1_000_000_000_000)) { result[key] = row }
            return Array(result.values)
        }
    }

    func loadMarkers() -> [MessageKey: Int] {
        queue.sync {
            guard open(), flushPending(), let statement = statement("SELECT key, value FROM markers") else { return [:] }
            defer { sqlite3_reset(statement) }
            var result = [MessageKey: Int]()
            var status = sqlite3_step(statement)
            while status == SQLITE_ROW {
                if let raw = sqlite3_column_text(statement, 0), let key = MessageKey(storageKey: String(cString: raw)) {
                    result[key] = Int(sqlite3_column_int64(statement, 1))
                }
                status = sqlite3_step(statement)
            }
            if status != SQLITE_DONE { reportError() }
            return result
        }
    }

    private func scheduleFlush() {
        guard !flushScheduled else { return }
        flushScheduled = true
        queue.asyncAfter(deadline: .now() + 0.01) { [self] in
            flushScheduled = false
            _ = flushPending()
        }
    }

    @discardableResult
    private func flushPending() -> Bool {
        guard !pendingRevisions.isEmpty || !removedRevisions.isEmpty || !pendingSnapshots.isEmpty ||
              !removedSnapshots.isEmpty || !pendingMarkers.isEmpty else { return true }
        guard open(), execute("BEGIN IMMEDIATE") else { return false }
        var success = true
        for (key, value) in pendingRevisions where success { success = write(value, key: key) }
        for key in removedRevisions where success { success = mutate("DELETE FROM revisions WHERE key = ?", key: key) }
        for (key, row) in pendingSnapshots where success {
            success = mutate("INSERT OR REPLACE INTO snapshots VALUES (?, ?, ?)", key: key.storageKey, data: row.bytes, integer: row.position)
        }
        for key in removedSnapshots where success { success = mutate("DELETE FROM snapshots WHERE key = ?", key: key.storageKey) }
        for (key, value) in pendingMarkers where success {
            success = mutate("INSERT OR REPLACE INTO markers VALUES (?, ?)", key: key.storageKey, integer: Int64(value))
        }
        guard success, execute("COMMIT") else { _ = execute("ROLLBACK"); return false }
#if TGEXTRA_TESTING
        commits += 1
#endif
        pendingRevisions.removeAll(); removedRevisions.removeAll()
        pendingSnapshots.removeAll(); removedSnapshots.removeAll(); pendingMarkers.removeAll()
        return true
    }

    func save(_ value: [String: Any], key: MessageKey) { save([key: value]) }

    func save(_ values: [MessageKey: [String: Any]]) {
        queue.async { [self] in
            for (key, value) in values { pendingRevisions[key.storageKey] = value; removedRevisions.remove(key.storageKey) }
            scheduleFlush()
        }
    }

    func remove(_ key: MessageKey) {
        queue.async { [self] in
            pendingRevisions.removeValue(forKey: key.storageKey)
            removedRevisions.insert(key.storageKey)
            scheduleFlush()
        }
    }

    func saveMessageData(snapshots: [MessageSnapshotRow], removing: Set<MessageKey>, markers: [MessageKey: Int]) {
        queue.async { [self] in
            for row in snapshots { pendingSnapshots[row.key] = row; removedSnapshots.remove(row.key) }
            for key in removing { pendingSnapshots.removeValue(forKey: key); removedSnapshots.insert(key) }
            pendingMarkers.merge(markers) { _, latest in latest }
            _ = flushPending()
        }
    }

    @discardableResult
    func clear() -> Bool {
        queue.sync {
            guard open(), execute("BEGIN IMMEDIATE") else { return false }
            guard execute("DELETE FROM revisions"), execute("DELETE FROM snapshots"), execute("DELETE FROM markers"),
                  execute("DELETE FROM message_data_migration"), execute("INSERT INTO message_data_migration VALUES (1)"),
                  execute("PRAGMA user_version=1"), execute("COMMIT") else {
                _ = execute("ROLLBACK"); return false
            }
            pendingRevisions.removeAll(); removedRevisions.removeAll()
            pendingSnapshots.removeAll(); removedSnapshots.removeAll(); pendingMarkers.removeAll()
            // DELETE frees pages for SQLite reuse; VACUUM returns them to the OS.
            // The deletion is already committed even if compaction cannot finish.
            for statement in statements.values { sqlite3_finalize(statement) }
            statements.removeAll()
            if execute("VACUUM") {
                if sqlite3_wal_checkpoint_v2(database, nil, SQLITE_CHECKPOINT_TRUNCATE, nil, nil) != SQLITE_OK {
                    reportError()
                }
            }
            return true
        }
    }

#if TGEXTRA_TESTING
    func setReadOnly(_ enabled: Bool) {
        queue.sync { if open() { _ = flushPending(); _ = execute("PRAGMA query_only=\(enabled ? 1 : 0)") } }
    }
    var commitCount: Int { queue.sync { _ = flushPending(); return commits } }
    var changeCount: Int { queue.sync { _ = flushPending(); return Int(sqlite3_total_changes(database)) } }
#endif
}
