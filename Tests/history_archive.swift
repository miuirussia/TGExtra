import Foundation

func testHistoryArchive() {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let path = directory.appendingPathComponent("History.sqlite").path
    let key = MessageKey(account: "account-1", peer: 42, id: 1)
    let original: [String: Any] = ["versions": ["A", "B"], "editDate": 1,
                                   "contents": [["entities": Data([1, 2])], [:]]]
    do {
        let archive = MessageHistoryArchive(path: path)
        let legacy = Dictionary(uniqueKeysWithValues: (1...3000).map { ("account-1:42:\($0)", original) })
        check(archive.migrate(legacy), "Migrate the complete legacy history in one transaction")
        let before = archive.changeCount
        archive.save(["versions": ["A", "B", "C"]], key: key)
        let saved = archive.load()
        check(archive.changeCount == before + 1 && saved.count == 3000,
              "One edit updates one archived message regardless of history size")
        check(archive.migrate(legacy), "Migration is idempotent")
        check(archive.load()[key.storageKey]?["versions"] as? [String] == ["A", "B", "C"],
              "Repeated migration preserves newer archived revisions")
    }
    let reopened = MessageHistoryArchive(path: path)
    check(reopened.load()[key.storageKey]?["versions"] as? [String] == ["A", "B", "C"],
          "History survives reopening its database")
    check((reopened.load()["account-1:42:2"]?["contents"] as? [[String: Data]])?.first?["entities"] == Data([1, 2]),
          "Migration preserves binary revision content")
    reopened.remove(key)
    check(reopened.load()[key.storageKey] == nil, "Discarded messages are removed from disk")
    check(reopened.migrate([key.storageKey: original]) && reopened.load()[key.storageKey] == nil,
          "Stale defaults cannot resurrect an entry after migration and deletion")
    reopened.save(original, key: key)
    reopened.clear()
    check(reopened.load().isEmpty, "Clear drains pending writes before deleting all accounts")
    check(reopened.migrate([key.storageKey: original]) && reopened.load().isEmpty,
          "Cleared history stays cleared if the old preferences file reappears")
    let unavailable = MessageHistoryArchive(path: "/dev/null/History.sqlite")
    check(!unavailable.migrate([key.storageKey: original]), "Failed migration never claims to have saved the legacy archive")
    let readOnly = MessageHistoryArchive(path: ":memory:")
    let unsaved = MessageHistoryStore(archive: readOnly)
    _ = unsaved.record("A", key: key, editDate: nil, content: [:])
    _ = unsaved.record("B", key: key, editDate: 1, content: [:])
    _ = readOnly.load()
    readOnly.setReadOnly(true)
    check(!unsaved.clear() && unsaved.versions(for: key) == ["A", "B"],
          "A failed disk clear reports failure and preserves the in-memory history")
    let blocked = directory.appendingPathComponent("blocked")
    try! Data("blocker".utf8).write(to: blocked)
    let recovering = MessageHistoryArchive(path: blocked.appendingPathComponent("History.sqlite").path)
    let recoveringStore = MessageHistoryStore(archive: recovering)
    check(!recoveringStore.record("temporary", key: key, editDate: nil, content: [:]),
          "Unreadable storage cannot replace an existing message with a fresh original")
    try! FileManager.default.removeItem(at: blocked)
    check(recovering.migrate([key.storageKey: original]), "Storage recovers after a temporary directory failure")
    check(recoveringStore.record("C", key: key, editDate: 2, content: [:]) &&
          recoveringStore.versions(for: key) == ["A", "B", "C"], "Retry initialization and retain older revisions after storage recovers")
    print("PASS incremental history archive, migration, reopen, binary content, removal and queued clearing")
}
