import XCTest
@testable import QundaoCore

final class SnapshotSummarizerTests: XCTestCase {
  private func result(_ text: String = "整理结果") -> AIResult {
    AIResult(summary: text, relevant: false, relevanceReason: "无关", evidenceIDs: [], judgements: [])
  }
  private func message(_ id: Int, _ text: String) -> Message {
    Message(id: "M\(id)", accountID: "a", groupID: "g", senderID: "s", sender: "同事", text: text, timestamp: Int64(id))
  }
  func testAllUnreadAndOversizedUnicodeMessageReachModelWithoutTruncation() async throws {
    let giant = String(repeating: "长消息🙂\n\"引号\"\\", count: 300)
    let messages = (1...10).map { message($0, "完整消息\($0)" + String(repeating: "测试", count: 120)) } + [message(11, giant)]
    var received: [String: String] = [:], mapCalls = 0, reduceCalls = 0
    let summarizer = SnapshotSummarizer(budget: 1400, names: ["我"], keywords: [], selfID: "me")
    _ = try await summarizer.run(messages) { input, _ in
      XCTAssertLessThanOrEqual(try input.encoded().count, 1400)
      if input.messages.isEmpty { reduceCalls += 1; XCTAssertFalse(input.notes.isEmpty) }
      else {
        mapCalls += 1
        for message in input.messages { received[message.id, default: ""] += message.text }
      }
      return self.result()
    }
    XCTAssertGreaterThan(mapCalls, 10); XCTAssertGreaterThan(reduceCalls, 0)
    XCTAssertEqual(received.count, messages.count)
    for message in messages { XCTAssertEqual(received[message.id], message.text) }
  }
  func testAllChunkResultsReachReduction() async throws {
    let messages = (1...30).map { message($0, String(repeating: "x", count: 450)) }
    var mapIDs = Set<String>(), notes = ""
    _ = try await SnapshotSummarizer(budget: 1800, names: [], keywords: [], selfID: "me").run(messages) { input, _ in
      if !input.messages.isEmpty {
        let ids = input.messages.map(\.id); mapIDs.formUnion(ids)
        return self.result(ids.joined(separator: ","))
      }
      notes += input.notes.joined()
      return self.result("汇总")
    }
    XCTAssertEqual(mapIDs.count, 30)
    for id in mapIDs { XCTAssertTrue(notes.contains(id)) }
  }
  func testPartialFailureNeverProducesFinalResult() async {
    let messages = (1...5).map { message($0, String(repeating: "x", count: 600)) }
    var calls = 0
    do {
      _ = try await SnapshotSummarizer(budget: 1000, names: [], keywords: [], selfID: "me").run(messages) { input, _ in
        calls += 1
        XCTAssertFalse(input.messages.isEmpty, "分段未全完成不得进入汇总")
        if calls == 2 { throw AppFailure.message("分段失败") }
        return self.result()
      }
      XCTFail("部分失败不能返回成功")
    } catch { XCTAssertEqual(calls, 2) }
  }
  func testInvalidReductionEvidenceFailsWholeSnapshot() async {
    do {
      _ = try await SnapshotSummarizer(budget: 1000, names: [], keywords: [], selfID: "me").run([
        message(1, String(repeating: "x", count: 700)), message(2, String(repeating: "y", count: 700))
      ]) { input, _ in
        if !input.messages.isEmpty { return self.result() }
        return AIResult(summary: "非法引用", relevant: true, relevanceReason: "引用", evidenceIDs: ["不存在"], judgements: [])
      }
      XCTFail("汇总证据非法不能推进标记")
    } catch { XCTAssertTrue(error.localizedDescription.contains("证据")) }
  }
  func testReductionCannotCiteAnotherGroupOfNotes() async {
    let messages = (1...3).map { message($0, String(repeating: "x", count: 700)) }
    let allIDs = Set(messages.map(\.id))
    var reachedReduction = false
    do {
      _ = try await SnapshotSummarizer(budget: 1000, names: [], keywords: [], selfID: "me").run(messages) { input, _ in
        if let message = input.messages.first {
          return AIResult(summary: String(repeating: "整理", count: 180), relevant: true,
                          relevanceReason: "工作事项", evidenceIDs: [message.id], judgements: [])
        }
        reachedReduction = true
        let visible = Set(allIDs.filter { input.notes.joined().contains("\"\($0)\"") })
        let missing = try XCTUnwrap(allIDs.subtracting(visible).first)
        return AIResult(summary: "引用了另一组的消息", relevant: true, relevanceReason: "伪造引用",
                        evidenceIDs: [missing], judgements: [])
      }
      XCTFail("当前汇总输入以外的消息即使属于整个快照也不能引用")
    } catch { XCTAssertTrue(error.localizedDescription.contains("证据")) }
    XCTAssertTrue(reachedReduction)
  }
  func testSingleOversizedCombinedCharacterIsFullySplit() async throws {
    let text = "a" + String(repeating: "\u{301}", count: 1500)
    XCTAssertEqual(text.count, 1)
    var received = ""
    _ = try await SnapshotSummarizer(budget: 1000, names: [], keywords: [], selfID: "me").run([message(1, text)]) { input, _ in
      XCTAssertLessThanOrEqual(try input.encoded().count, 1000)
      received += input.messages.map(\.text).joined()
      return self.result()
    }
    XCTAssertEqual(Array(received.utf8), Array(text.utf8))
  }
  func testLongNotesKeepWholeEscapedEvidenceIDsAndOnlyExposeVisibleReferences() async throws {
    let messages = (1...3).map { n in
      Message(id: "M\(n)-\"\\" + String(repeating: "x", count: 220), accountID: "a", groupID: "g",
              senderID: "s", sender: "同事", text: String(repeating: "正文", count: 500), timestamp: Int64(n))
    }
    let tokens = try Dictionary(uniqueKeysWithValues: messages.map {
      ($0.id, String(decoding: try JSONEncoder().encode($0.id), as: UTF8.self))
    })
    var visibleDuringReduction = Set<String>()
    _ = try await SnapshotSummarizer(budget: 1200, names: [], keywords: [], selfID: "me").run(messages) { input, allowed in
      XCTAssertLessThanOrEqual(try input.encoded().count, 1200)
      if let message = input.messages.first {
        return AIResult(summary: String(repeating: "完整整理", count: 140), relevant: true,
                        relevanceReason: "工作事项", evidenceIDs: [message.id], judgements: [])
      }
      let visible = Set(tokens.filter { _, token in input.notes.contains { $0.contains(token) } }.keys)
      XCTAssertEqual(allowed, visible)
      visibleDuringReduction.formUnion(visible)
      return AIResult(summary: "继续汇总", relevant: !allowed.isEmpty, relevanceReason: "工作事项",
                      evidenceIDs: allowed.sorted(), judgements: [])
    }
    XCTAssertEqual(visibleDuringReduction, Set(messages.map(\.id)), "证据 ID 不能在拆片时被切断或丢失")
  }
}
