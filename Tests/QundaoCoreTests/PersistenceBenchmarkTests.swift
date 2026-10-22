import Foundation
import XCTest
@testable import QundaoCore

/// 合成数据的保存耗时基准；只在设置 QUNDAO_BENCH=1 时运行，避免拖慢常规测试。
final class PersistenceBenchmarkTests: XCTestCase {
  func testIncrementalSaveCost() throws {
    guard ProcessInfo.processInfo.environment["QUNDAO_BENCH"] == "1" else { throw XCTSkip("设置 QUNDAO_BENCH=1 运行基准") }
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("qundao-bench-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: dir) }
    var snapshot = AppSnapshot()
    snapshot.preferences.accountID = "a"
    snapshot.groups = (0..<60).map { ChatGroup(id: "g\($0)@chatroom", name: "合成群 \($0)", unread: $0 % 5) }
    snapshot.messages = (0..<400).map { Message(id: "m\($0)", accountID: "a", groupID: "g\($0 % 50)@chatroom", senderID: "s\($0 % 9)",
      sender: "同事\($0 % 9)", text: String(repeating: "合成消息内容", count: 30), timestamp: Int64(1_000_000 + $0)) }
    snapshot.digests = (0..<57).map { i in Digest(accountID: "a", groupID: "g\(i % 50)@chatroom", groupName: "合成群", text: String(repeating: "摘要", count: 200),
      count: 7, evidence: Array(snapshot.messages[(i * 7) % 390 ..< (i * 7) % 390 + 7]), related: i % 3 == 0, relevanceReason: "合成") }
    snapshot.analyzed = Set((0..<1000).map { "a|g\($0 % 50)@chatroom|analyzed-message-\($0)" })
    snapshot.seen = Set((0..<1100).map { "a|g\($0 % 50)@chatroom|seen-message-\($0)" })
    for i in 0..<50 { snapshot.checkpoints["a|g\(i)@chatroom"] = Checkpoint(after: Int64(i)) }
    let persistence = SnapshotPersistence(directory: dir)
    _ = try persistence.load()
    try persistence.save(snapshot)
    let rounds = 50
    let start = Date()
    for i in 0..<rounds {
      snapshot.checkpoints["a|g\(i)@chatroom"]?.after += 1
      try persistence.save(snapshot)
    }
    let checkpointMS = Date().timeIntervalSince(start) * 1000 / Double(rounds)
    let idleStart = Date()
    for _ in 0..<rounds { try persistence.save(snapshot) }
    let idleMS = Date().timeIntervalSince(idleStart) * 1000 / Double(rounds)
    print("BENCH checkpoint-save \(String(format: "%.2f", checkpointMS)) ms, unchanged-save \(String(format: "%.2f", idleMS)) ms")
  }
}
