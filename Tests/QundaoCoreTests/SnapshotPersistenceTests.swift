import SQLite3
import XCTest
@testable import QundaoCore

final class SnapshotPersistenceTests: XCTestCase {
  private func tempDirectory() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  }
  private func message(_ id: String, group: String = "g") -> Message {
    Message(id: id, accountID: "a", groupID: group, senderID: "s", sender: "同事", text: "原文\(id)", timestamp: Int64(id.dropFirst()) ?? 0)
  }
  private func digest(_ text: String) -> Digest {
    Digest(accountID: "a", groupID: "g", groupName: "群", text: text, count: 1, evidence: [message("M1")], related: true, relevanceReason: "")
  }
  /// 统计 SQLite 中 records 表实际变更的行数（WAL 提交次数不可靠，按 total_changes 计）。
  private func changes(_ body: () throws -> Void, in directory: URL) rethrows -> Int32 {
    var db: OpaquePointer?
    sqlite3_open(directory.appendingPathComponent(SnapshotPersistence.databaseName).path, &db)
    defer { sqlite3_close(db) }
    func count() -> Int32 {
      var statement: OpaquePointer?
      sqlite3_prepare_v2(db, "SELECT COALESCE(SUM(length(payload)),0) + COUNT(*) * 1000003 FROM records", -1, &statement, nil)
      defer { sqlite3_finalize(statement) }
      sqlite3_step(statement)
      return Int32(truncatingIfNeeded: sqlite3_column_int64(statement, 0))
    }
    let before = count()
    try body()
    return count() &- before
  }

  func testResultMarkerAndPendingStateSurviveActualFileRestartTogether() throws {
    let directory = tempDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let disk = SnapshotPersistence(directory: directory)
    let scope = ConversationScope(account: "a", group: "g")
    let message = Message(id: "M100", accountID: "a", groupID: "g", senderID: "s", sender: "同事", text: "原文", timestamp: 100)
    let unread = UnreadSnapshot(scope: scope, groupName: "群", messages: [message])
    var state = AppSnapshot(); state.summaryState = SummaryState()
    state.summaryState?.jobs[scope.key] = SummaryJob(scope: scope, trigger: .immediate)
    try disk.save(state)
    state.summaryState?.markers[scope.key] = SummaryMarker(snapshot: unread)
    state.summaryState?.jobs[scope.key] = nil
    state.digests.append(Digest(accountID: "a", groupID: "g", groupName: "群", text: "摘要", count: 1, evidence: [message], related: false, relevanceReason: "无关"))
    try disk.save(state)
    let restored = try SnapshotPersistence(directory: directory).load()
    XCTAssertEqual(restored.summaryState?.markers[scope.key]?.lastMessageID, restored.digests[0].evidence.last?.id)
    XCTAssertTrue(restored.summaryState!.jobs.isEmpty)
    let permissions = try FileManager.default.attributesOfItem(
      atPath: directory.appendingPathComponent(SnapshotPersistence.databaseName).path)[.posixPermissions] as? Int
    XCTAssertEqual(permissions, 0o600)
    XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("state.json").path))
  }

  func testEmptyDirectoryLoadsDefaults() throws {
    let directory = tempDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let state = try SnapshotPersistence(directory: directory).load()
    XCTAssertTrue(state.digests.isEmpty); XCTAssertEqual(state.preferences.intervalMinutes, 15)
    XCTAssertNil(state.summaryState)
  }

  func testDockVisibilitySurvivesRestartWithoutChangingAutoListen() throws {
    let directory = tempDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let disk = SnapshotPersistence(directory: directory)
    var state = AppSnapshot()
    state.preferences.autoStart = true
    for hidden in [true, false] {
      state.preferences.hideDockIcon = hidden
      try disk.save(state)
      let restored = try SnapshotPersistence(directory: directory).load()
      XCTAssertEqual(restored.preferences.hidesDockIcon, hidden)
      XCTAssertTrue(restored.preferences.autoStart)
    }
  }

  func testLegacyPreferencesWithoutDockFieldRemainReadable() throws {
    var state = AppSnapshot()
    state.preferences.autoStart = true
    state.preferences.selectedGroups = ["合成群@chatroom"]
    let legacy = try JSONEncoder().encode(state)
    let restored = try JSONDecoder().decode(AppSnapshot.self, from: legacy)
    XCTAssertNil(restored.preferences.hideDockIcon)
    XCTAssertFalse(restored.preferences.hidesDockIcon)
    XCTAssertTrue(restored.preferences.autoStart)
    XCTAssertEqual(restored.preferences.selectedGroups, state.preferences.selectedGroups)
  }

  func testLegacyJSONImportedOnceAndBackedUpWithoutLoss() throws {
    let directory = tempDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    var old = AppSnapshot()
    old.preferences.accountID = "a"; old.preferences.selectedGroups = ["g@chatroom"]
    old.groups = [ChatGroup(id: "g@chatroom", name: "群", unread: 3)]
    old.messages = [message("M1"), message("M2")]
    old.digests = [digest("一"), digest("二")]
    old.seen = ["x", "y"]
    let scope = ConversationScope(account: "a", group: "g")
    old.summaryState = SummaryState()
    old.summaryState?.markers[scope.key] = SummaryMarker(snapshot: UnreadSnapshot(scope: scope, groupName: "群", messages: [message("M2")]))
    try JSONEncoder().encode(old).write(to: directory.appendingPathComponent("state.json"))

    let restored = try SnapshotPersistence(directory: directory).load()
    XCTAssertEqual(restored.messages, old.messages)
    XCTAssertEqual(restored.digests.map(\.text), ["一", "二"])
    XCTAssertEqual(restored.seen, old.seen)
    XCTAssertEqual(restored.preferences.selectedGroups, ["g@chatroom"])
    XCTAssertEqual(restored.summaryState?.markers[scope.key]?.lastMessageID, "M2", "成功标记必须原样迁移")
    XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("state.json").path))
    XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent("state.json.migrated").path))

    // 再次启动不重复导入；即使旧文件被恢复也以数据库为准。
    try FileManager.default.copyItem(at: directory.appendingPathComponent("state.json.migrated"),
                                     to: directory.appendingPathComponent("state.json"))
    let disk = SnapshotPersistence(directory: directory)
    var again = try disk.load()
    XCTAssertEqual(again.digests.count, 2)
    again.digests.append(digest("三"))
    try disk.save(again)
    XCTAssertEqual(try SnapshotPersistence(directory: directory).load().digests.map(\.text), ["一", "二", "三"])
  }

  func testCorruptLegacyJSONIsNotOverwritten() throws {
    let directory = tempDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let legacy = directory.appendingPathComponent("state.json")
    try Data("{坏".utf8).write(to: legacy)
    XCTAssertThrowsError(try SnapshotPersistence(directory: directory).load())
    XCTAssertEqual(try Data(contentsOf: legacy), Data("{坏".utf8))
  }

  func testOnlyChangedRowsAreWrittenAndOrderIsPreserved() throws {
    let directory = tempDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let disk = SnapshotPersistence(directory: directory)
    var state = AppSnapshot()
    state.digests = (0..<50).map { digest("摘要\($0)") }
    try disk.save(state)
    // 无变化：不写任何行。
    XCTAssertEqual(try changes({ try disk.save(state) }, in: directory), 0)
    // 已阅一条：只改一行，其余摘要不重写。
    state.digests[10].attentionReadAt = Date(timeIntervalSince1970: 5)
    let delta = try changes({ try disk.save(state) }, in: directory)
    XCTAssertLessThan(abs(delta), 1000, "只应更新一行，行数不变")
    // 追加、裁剪最旧、再追加后顺序正确。
    state.digests.append(digest("新增"))
    state.digests = Array(state.digests.suffix(50))
    try disk.save(state)
    let restored = try SnapshotPersistence(directory: directory).load()
    XCTAssertEqual(restored.digests.map(\.text), state.digests.map(\.text))
    XCTAssertNotNil(restored.digests.first(where: { $0.text == "摘要10" })?.attentionReadAt)
    // 重排后也按数组顺序恢复。
    state.digests.reverse()
    try disk.save(state)
    XCTAssertEqual(try SnapshotPersistence(directory: directory).load().digests.map(\.text), state.digests.map(\.text))
  }

  func testFailedCommitKeepsPreviousStateAndRetriesFullDifference() throws {
    let directory = tempDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let disk = SnapshotPersistence(directory: directory)
    var state = AppSnapshot(); state.digests = [digest("一")]
    try disk.save(state)
    // 另一个连接持有写锁，模拟落盘失败。
    var blocker: OpaquePointer?
    sqlite3_open(directory.appendingPathComponent(SnapshotPersistence.databaseName).path, &blocker)
    sqlite3_busy_timeout(blocker, 0)
    XCTAssertEqual(sqlite3_exec(blocker, "BEGIN IMMEDIATE", nil, nil, nil), SQLITE_OK)
    state.digests.append(digest("二"))
    XCTAssertThrowsError(try disk.save(state))
    sqlite3_exec(blocker, "ROLLBACK", nil, nil, nil); sqlite3_close(blocker)
    XCTAssertEqual(try SnapshotPersistence(directory: directory).load().digests.map(\.text), ["一"], "失败不能部分提交")
    try disk.save(state)
    XCTAssertEqual(try SnapshotPersistence(directory: directory).load().digests.map(\.text), ["一", "二"])
  }
}
