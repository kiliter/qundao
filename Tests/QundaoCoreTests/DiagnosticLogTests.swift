import XCTest
@testable import QundaoCore

final class DiagnosticLogTests: XCTestCase {
  private func archive(_ max: UInt64 = 10000000) -> DiagnosticLogStore {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("qundao-logs-test-" + UUID().uuidString)
    addTeardownBlock { try? FileManager.default.removeItem(at: url) }
    return DiagnosticLogStore(directory: url, maxFileBytes: max)
  }
  func testPaginationStaysStableWhileNewRecordsArriveAndFilesRotate() throws {
    let store = archive(800)
    var ids: [UUID] = []
    for i in 0..<130 {
      let record = DiagnosticRecord(category: i % 2 == 0 ? .jev : .local, event: "测试 \(i)", input: "中文入参", output: "结果")
      ids.append(record.id); try store.append(record)
    }
    let first = try store.page(limit: 50)
    XCTAssertEqual(first.records.map(\.id), Array(ids.reversed().prefix(50)))
    XCTAssertNotNil(first.next)
    try store.append(DiagnosticRecord(category: .cpa, event: "分页后追加"))
    let second = try store.page(before: first.next, limit: 50)
    let third = try store.page(before: second.next, limit: 50)
    XCTAssertEqual((first.records + second.records + third.records).map(\.id), ids.reversed())
    XCTAssertNil(third.next)
    let filtered = try store.page(category: .jev, limit: 100)
    XCTAssertEqual(filtered.records.count, 65)
    XCTAssertTrue(filtered.records.allSatisfy { $0.category == .jev })
  }
  func testLargeUnicodeRecordAcrossChunksAndRestart() throws {
    let store = archive()
    let text = String(repeating: "中文消息😀\n", count: 18000)
    try store.append(DiagnosticRecord(category: .cpa, event: "完整内容", input: text, output: "成功"))
    try store.append(DiagnosticRecord(category: .local, event: "后续"))
    let reopened = DiagnosticLogStore(directory: store.directory)
    let first = try reopened.page(limit: 1)
    let older = try reopened.page(before: first.next, limit: 1)
    XCTAssertEqual(older.records.first?.input, text)
    XCTAssertNil(older.next)
    let files = try FileManager.default.contentsOfDirectory(at: store.directory, includingPropertiesForKeys: nil)
    let permissions = try FileManager.default.attributesOfItem(atPath: files[0].path)[.posixPermissions] as? NSNumber
    XCTAssertEqual(permissions?.intValue, 0o600)
  }
  func testSecretsRedactedButInputsAndProbabilitiesRemain() throws {
    let data = try JSONSerialization.data(withJSONObject: ["authorization": "Bearer secret", "nested": ["api_key": "secret"],
      "text": "服务回显 synthetic-key，普通消息", "noul": 0.83])
    let text = DiagnosticRecord.safeText(data, secrets: ["synthetic-key"])
    XCTAssertFalse(text.contains("secret"))
    XCTAssertFalse(text.contains("synthetic-key"))
    XCTAssertTrue(text.contains("普通消息"))
    let output = try JSONSerialization.jsonObject(with: Data(text.utf8)) as! [String: Any]
    XCTAssertEqual(output["noul"] as? Double, 0.83)
  }
  func testEmptyArchiveAndInvalidTrailingLineDoNotHideValidHistory() throws {
    let store = archive()
    XCTAssertTrue(try store.page().records.isEmpty)
    try store.append(DiagnosticRecord(category: .local, event: "有效记录"))
    let file = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: store.directory, includingPropertiesForKeys: nil).first)
    let handle = try FileHandle(forWritingTo: file); try handle.seekToEnd()
    try handle.write(contentsOf: Data("{incomplete".utf8)); try handle.close()
    XCTAssertEqual(try store.page().records.map(\.event), ["有效记录"])
    try store.append(DiagnosticRecord(category: .local, event: "恢复写入"))
    XCTAssertEqual(try store.page().records.map(\.event), ["恢复写入", "有效记录"])
  }
  func testReadableViewExpandsEmbeddedJSONWithoutChangingStoredInput() throws {
    let source = #"{"input":[{"content":"{\"消息\":\"请确认\"}"}],"count":1}"#
    let readable = DiagnosticRecord.readableText(source)
    let json = try JSONSerialization.jsonObject(with: Data(readable.utf8)) as! [String: Any]
    let input = json["input"] as! [[String: Any]]
    XCTAssertEqual((input[0]["content"] as? [String: String])?["消息"], "请确认")
    let original = try JSONSerialization.jsonObject(with: Data(source.utf8)) as! [String: Any]
    XCTAssertTrue((original["input"] as! [[String: Any]])[0]["content"] is String)
  }
  func testNewDiskRecordImmediatelyNotifiesWaitingReader() async throws {
    let store = archive()
    let updates = store.updates()
    let record = DiagnosticRecord(category: .local, event: "即时刷新测试")
    let received = expectation(description: "写入后即时收到版本变更")
    let reader = Task {
      for await revision in updates where revision > 0 {
        XCTAssertEqual(try store.page(limit: 1).records.first?.id, record.id, "收到事件时日志必须已落盘")
        received.fulfill()
        break
      }
    }
    defer { reader.cancel() }
    try store.append(record)
    await fulfillment(of: [received], timeout: 1)
    try await reader.value
  }
  func testBurstUpdatesCoalesceWithoutDroppingPersistedRecordsAndReachMultipleReaders() async throws {
    let store = archive(800)
    var first = store.updates().makeAsyncIterator()
    var second = store.updates().makeAsyncIterator()
    let initial = await first.next()
    XCTAssertEqual(initial, 0)
    for index in 0..<40 { try store.append(DiagnosticRecord(category: .runtime, event: "批量 \(index)")) }
    let firstVersion = await first.next(), secondVersion = await second.next()
    XCTAssertEqual(firstVersion, 40)
    XCTAssertEqual(secondVersion, 40)
    XCTAssertEqual(try store.page(limit: 50).records.count, 40)
  }
}
