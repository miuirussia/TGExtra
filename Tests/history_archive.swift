import Foundation

func testHistoryArchive() {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let path = directory.appendingPathComponent("History.sqlite").path
    let key = MessageKey(account: "account-1", peer: 42, id: 1)
    testRevisionDates(directory: directory, key: key)
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
    let archiveBytes = { () -> UInt64 in
        ["", "-wal", "-shm"].reduce(0) { total, suffix in
            total + ((try? FileManager.default.attributesOfItem(atPath: path + suffix)[.size] as? NSNumber)?.uint64Value ?? 0)
        }
    }
    _ = reopened.changeCount
    let bytesBeforeClear = archiveBytes()
    reopened.clear()
    check(reopened.load().isEmpty, "Clear drains pending writes before deleting all accounts")
    check(archiveBytes() < bytesBeforeClear / 2, "Clearing a populated archive releases database and WAL disk space")
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
    _ = recovering.load()
    let dataKey = MessageKey(account: "account-2", peer: -1_000_000_000_077, id: 7)
    let legacySnapshot = ["messages": [dataKey.storageKey: Data([1, 2, 3])], "order": [dataKey.storageKey]] as [String: Any]
    check(reopened.migrateMessageData(snapshots: legacySnapshot, markers: [dataKey.storageKey: 1]), "Clearing keeps migration complete")
    check(reopened.loadSnapshots().isEmpty && reopened.loadMarkers().isEmpty, "Stale defaults cannot repopulate cleared data")
    let dataPath = directory.appendingPathComponent("MessageData.sqlite").path
    do {
        let data = MessageHistoryArchive(path: dataPath)
        check(data.migrateMessageData(snapshots: legacySnapshot, markers: [dataKey.storageKey: 1]), "Migrate legacy snapshots and markers together")
        check(data.loadSnapshots().first?.bytes == Data([1, 2, 3]) && data.loadMarkers()[dataKey] == 1, "Preserve legacy bytes and markers")
        let before = data.commitCount
        let batch = Dictionary(uniqueKeysWithValues: (1...1000).map {
            (MessageKey(account: "account-1", peer: 42, id: Int32($0)), ["versions": ["A", "B"]] as [String: Any])
        })
        data.save(batch)
        check(data.load().count == 1000 && data.commitCount == before + 1, "Batch revisions in one durable transaction")
        data.saveMessageData(snapshots: [MessageSnapshotRow(key: dataKey, bytes: Data([4, 5]), position: 2)], removing: [], markers: [dataKey: 3])
        check(data.loadMarkers()[dataKey] == 3, "Incremental marker updates are committed with snapshots")
        check(data.migrateMessageData(snapshots: legacySnapshot, markers: [dataKey.storageKey: 1]) && data.loadSnapshots().first?.bytes == Data([4, 5]), "Repeated migration preserves newer snapshots")
        data.setReadOnly(true)
        data.saveMessageData(snapshots: [], removing: [], markers: [dataKey: 7])
        data.setReadOnly(false)
        check(data.loadMarkers()[dataKey] == 7, "Retry a failed transaction without losing its pending delta")
    }
    let data = MessageHistoryArchive(path: dataPath)
    check(data.loadSnapshots().first?.bytes == Data([4, 5]) && data.loadMarkers()[dataKey] == 7, "Reopen migrated message data")
    data.saveMessageData(snapshots: [], removing: [dataKey], markers: [:])
    check(data.loadSnapshots().isEmpty, "Persist snapshot eviction incrementally")
    data.saveMessageData(snapshots: [MessageSnapshotRow(key: dataKey, bytes: Data([6]), position: 3)], removing: [], markers: [:])
    check(data.clear() && data.load().isEmpty && data.loadSnapshots().isEmpty && data.loadMarkers().isEmpty, "Clear all message tables and pending writes together")
    print("PASS incremental history archive, migration, reopen, binary content, removal and queued clearing")

    let boundedArchive = MessageHistoryArchive(path: directory.appendingPathComponent("Bounded.sqlite").path)
    let bounded = MessageHistoryStore(archive: boundedArchive)
    for id: Int32 in 1...2501 {
        let message = MessageKey(account: "account-1", peer: 42, id: id)
        _ = bounded.record("original \(id)", key: message, editDate: nil, content: [:])
        _ = bounded.record("edited \(id)", key: message, editDate: 1, content: [:])
    }
    check(bounded.cachedEntryCount <= 2000, "Edited histories have a bounded memory cache")
    check(bounded.versions(for: key) == ["original 1", "edited 1"], "Evicted revisions remain available from disk")
    check(bounded.record("new edit", key: key, editDate: 2, content: [:]) &&
          bounded.versions(for: key) == ["original 1", "edited 1", "new edit"], "Append to an evicted history without losing older revisions")
    let lazy = MessageHistoryStore(archive: boundedArchive)
    lazy.load()
    check(lazy.cachedEntryCount == 0, "Opening an archive does not load every revision into memory")
    check(lazy.details(for: key)?.count == 3, "Lazy history reads retain revision details")
    check(lazy.discard(MessageKey(account: "account-1", peer: 42, id: 2)) &&
          boundedArchive.revision(for: MessageKey(account: "account-1", peer: 42, id: 2)) == nil,
          "Discard removes histories that have not been loaded into the cache")
    let lookups = MessageHistoryArchive(path: ":memory:")
    let account = "account_a%"
    let cloud = MessageKey(account: account, peer: 42, id: 7)
    let channel = MessageKey(account: account, peer: -1_000_000_000_077, id: 7)
    let otherAccount = MessageKey(account: "accountXaZ", peer: 42, id: 7)
    lookups.saveMessageData(snapshots: [MessageSnapshotRow(key: cloud, bytes: Data([1]), position: 1),
        MessageSnapshotRow(key: channel, bytes: Data([2]), position: 2),
        MessageSnapshotRow(key: otherAccount, bytes: Data([3]), position: 3)], removing: [], markers: [:])
    check(lookups.snapshots(account: account, id: 7, peer: nil).map(\.key) == [cloud],
          "Lazy cloud lookup escapes account patterns and excludes channel snapshots")
    check(lookups.snapshots(account: account, id: 7, peer: channel.peer).first?.key == channel,
          "Lazy channel lookup uses the exact account, peer and message id")
    lookups.setReadOnly(true)
    lookups.saveMessageData(snapshots: [MessageSnapshotRow(key: cloud, bytes: Data([4]), position: 4)], removing: [], markers: [:])
    check(lookups.snapshots(account: account, id: 7, peer: nil).first?.bytes == Data([4]),
          "Lazy reads see pending bytes after a failed disk write")
    lookups.saveMessageData(snapshots: [], removing: [cloud], markers: [:])
    check(lookups.snapshots(account: account, id: 7, peer: nil).isEmpty,
          "Lazy reads do not resurrect a pending snapshot removal")
    lookups.setReadOnly(false)
    print("PASS bounded revision cache, lazy reload, editing and discarding evicted histories")
}

private func testRevisionDates(directory: URL, key: MessageKey) {
    let path = directory.appendingPathComponent("Dates.sqlite").path
    let archive = MessageHistoryArchive(path: path)
    let store = MessageHistoryStore(archive: archive)
    _ = store.record("Original", key: key, editDate: nil, content: [:], messageDate: 100)
    _ = store.record("Edit", key: key, editDate: 200, content: [:], messageDate: 100)
    _ = store.record("Edit", key: key, editDate: 200, content: [:])
    _ = store.record("Stale", key: key, editDate: 150, content: [:])
    check(store.details(for: key)?.compactMap { $0["date"] as? Int32 } == [100, 200],
          "Original and edit use server dates; duplicate and stale observations preserve them")
    let observed = Int32(Date().timeIntervalSince1970)
    _ = store.record("Undated edit", key: key, editDate: nil, allowUndatedEdit: true, content: [:])
    let date = store.details(for: key)?.last?["date"] as? Int32 ?? 0
    check(date >= observed && date <= Int32(Date().timeIntervalSince1970), "Undated edits retain their observation time")
    _ = archive.load()
    let reopened = MessageHistoryStore(archive: MessageHistoryArchive(path: path))
    check(reopened.details(for: key)?.compactMap { $0["date"] as? Int32 } == [100, 200, date],
          "Each revision date survives reopening the database")
    for i: Int32 in 1...25 {
        _ = store.record("Edit \(i)", key: key, editDate: 300 + i, content: [:])
    }
    let trimmed = store.details(for: key)!
    check(trimmed.count == 20 && trimmed.first?["date"] as? Int32 == 100 &&
          trimmed.dropFirst().allSatisfy { detail in
              guard let text = detail["text"] as? String, let i = Int32(text.dropFirst(5)) else { return false }
              return detail["date"] as? Int32 == 300 + i
          }, "Trimming keeps the original timestamp and aligns every retained date with its revision")
    let legacyKey = MessageKey(account: key.account, peer: key.peer, id: 2)
    archive.save(["versions": ["Old", "Middle", "Latest"], "editDate": 900], key: legacyKey)
    let legacy = MessageHistoryStore(archive: archive)
    let details = legacy.details(for: legacyKey)!
    check(details[0]["date"] == nil && details[1]["date"] == nil && details[2]["date"] as? Int32 == 900,
          "Legacy archives recover only the known latest date without inventing earlier timestamps")
    _ = legacy.record("Next", key: legacyKey, editDate: 901, content: [:])
    let migrated = MessageHistoryStore(archive: archive).details(for: legacyKey)!
    check(migrated.count == 4 && migrated[0]["date"] == nil && migrated[3]["date"] as? Int32 == 901,
          "Appending to a legacy archive persists the new date alongside unknown old dates")
    print("PASS revision timestamps, duplicates, undated edits, trimming, legacy dates and database reopen")
}
