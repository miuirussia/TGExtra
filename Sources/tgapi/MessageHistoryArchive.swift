import Foundation
import SQLite3

final class MessageHistoryArchive {
    static let shared = MessageHistoryArchive(path: defaultPath)
    private static var defaultPath: String {
#if TGEXTRA_TESTING
        return ProcessInfo.processInfo.environment["TGEXTRA_TEST_HISTORY_PATH"] ?? ":memory:"
#else
        return NSHomeDirectory() + "/Library/Application Support/TGExtra/History.sqlite"
#endif
    }

    // load and clear drain earlier writes on the same queue.
    private let queue = DispatchQueue(label: "TGExtra.HistoryArchive", qos: .utility)
    private let path: String
    private var database: OpaquePointer?
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    init(path: String) { self.path = path }
    deinit { if let database = database { sqlite3_close(database) } }

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
              execute("CREATE TABLE IF NOT EXISTS revisions (key TEXT PRIMARY KEY, value BLOB NOT NULL)") else {
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

    private func reportError() {
        NSLog("[TGExtra] History archive: %s", sqlite3_errmsg(database))
    }

    private func write(_ value: [String: Any], key: String, preserveExisting: Bool = false) -> Bool {
        guard let data = try? PropertyListSerialization.data(fromPropertyList: value, format: .binary, options: 0) else { return false }
        var statement: OpaquePointer?
        let sql = preserveExisting ? "INSERT OR IGNORE INTO revisions VALUES (?, ?)" : "INSERT OR REPLACE INTO revisions VALUES (?, ?)"
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else { reportError(); return false }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_bind_text(statement, 1, key, -1, transient) == SQLITE_OK else { reportError(); return false }
        let bound = data.withUnsafeBytes { sqlite3_bind_blob(statement, 2, $0.baseAddress, Int32($0.count), transient) }
        guard bound == SQLITE_OK, sqlite3_step(statement) == SQLITE_DONE else { reportError(); return false }
        return true
    }

    func migrate(_ legacy: [String: [String: Any]]) -> Bool {
        queue.sync {
            guard open() else { return false }
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(database, "PRAGMA user_version", -1, &statement, nil) == SQLITE_OK else { reportError(); return false }
            let status = sqlite3_step(statement)
            let migrated = status == SQLITE_ROW && sqlite3_column_int(statement, 0) >= 1
            sqlite3_finalize(statement)
            guard status == SQLITE_ROW else { reportError(); return false }
            if migrated { return true }
            guard execute("BEGIN IMMEDIATE") else { return false }
            for (key, value) in legacy where MessageKey(storageKey: key) != nil {
                guard write(value, key: key, preserveExisting: true) else { _ = execute("ROLLBACK"); return false }
            }
            guard execute("PRAGMA user_version=1"), execute("COMMIT") else { _ = execute("ROLLBACK"); return false }
            return true
        }
    }

    func load() -> [String: [String: Any]] {
        queue.sync {
            guard open() else { return [:] }
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(database, "SELECT key, value FROM revisions", -1, &statement, nil) == SQLITE_OK else { reportError(); return [:] }
            defer { sqlite3_finalize(statement) }
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

    func save(_ value: [String: Any], key: MessageKey) {
        queue.async { if self.open() { _ = self.write(value, key: key.storageKey) } }
    }

    func remove(_ key: MessageKey) {
        queue.async {
            guard self.open() else { return }
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(self.database, "DELETE FROM revisions WHERE key = ?", -1, &statement, nil) == SQLITE_OK else { self.reportError(); return }
            defer { sqlite3_finalize(statement) }
            guard sqlite3_bind_text(statement, 1, key.storageKey, -1, self.transient) == SQLITE_OK,
                  sqlite3_step(statement) == SQLITE_DONE else { self.reportError(); return }
        }
    }

    @discardableResult
    func clear() -> Bool {
        queue.sync {
            guard open(), execute("BEGIN IMMEDIATE") else { return false }
            guard execute("DELETE FROM revisions"), execute("PRAGMA user_version=1"), execute("COMMIT") else {
                _ = execute("ROLLBACK")
                return false
            }
            return true
        }
    }

#if TGEXTRA_TESTING
    func setReadOnly(_ enabled: Bool) {
        queue.sync { if open() { _ = execute("PRAGMA query_only=\(enabled ? 1 : 0)") } }
    }
    var changeCount: Int { queue.sync { Int(sqlite3_total_changes(database)) } }
#endif
}
