import XCTest
@testable import QundaoCore

final class SnapshotPersistenceTests: XCTestCase {
  func testResultMarkerAndPendingStateSurviveActualFileRestartTogether() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
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
    let permissions = try FileManager.default.attributesOfItem(atPath: directory.appendingPathComponent("state.json").path)[.posixPermissions] as? Int
    XCTAssertEqual(permissions, 0o600)
    XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), ["state.json"])
  }
}
