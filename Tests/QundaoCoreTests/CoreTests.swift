import XCTest

@testable import QundaoCore

final class CoreTests: XCTestCase {
  func message(_ text: String, sender: String = "other", mentions: [String] = []) -> Message {
    Message(
      id: "42", accountID: "a", groupID: "g@chatroom", senderID: sender, sender: "同事", text: text,
      timestamp: 100, mentions: mentions)
  }
  func testStructuredMentionAndSelfExcluded() {
    XCTAssertEqual(
      RuleEngine.classify(message("请看看", mentions: ["me"]), selfID: "me", names: [], keywords: []),
      .definite("消息结构中明确 @ 你"))
    XCTAssertEqual(
      RuleEngine.classify(
        message("@嘉林 确认", sender: "me"), selfID: "me", names: ["嘉林"], keywords: ["确认"]), .none)
  }
  func testNameBoundaries() {
    if case .definite = RuleEngine.classify(
      message("@嘉林 帮忙确认"), selfID: "me", names: ["嘉林"], keywords: [])
    {
    } else {
      XCTFail("明确称呼未命中")
    }
    if case .definite = RuleEngine.classify(
      message("@嘉林三 帮忙确认"), selfID: "me", names: ["嘉林"], keywords: [])
    {
      XCTFail("同名前缀误命中")
    }
    XCTAssertEqual(
      RuleEngine.classify(message("谁找我？"), selfID: "me", names: ["嘉林"], keywords: []), .none)
    XCTAssertEqual(
      RuleEngine.classify(message("@嘉林三 帮忙确认"), selfID: "me", names: ["嘉林"], keywords: []), .none)
    XCTAssertEqual(
      RuleEngine.classify(message("＠小嘉林 帮忙确认"), selfID: "me", names: ["嘉林"], keywords: []), .none)
    XCTAssertEqual(
      RuleEngine.classify(message("@嘉林三 帮忙确认，嘉林也请看一下"), selfID: "me", names: ["嘉林"], keywords: []),
      .candidate("提到了你的称呼：嘉林"))
    XCTAssertEqual(
      RuleEngine.classify(message("@嘉林三 确认发布"), selfID: "me", names: ["嘉林"], keywords: ["发布"]),
      .candidate("涉及关注事项：发布"))
  }
  func testKeywordOnlyCandidate() {
    if case .candidate = RuleEngine.classify(
      message("签字接口明天讨论"), selfID: "me", names: [], keywords: ["签字接口"])
    {
    } else {
      XCTFail("关键词应进入候选")
    }
  }
  func testQueueDebouncesAndNoDuplicateFlight() {
    var q = AnalysisQueue()
    let t = Date(timeIntervalSince1970: 100)
    q.enqueue("g", now: t)
    q.enqueue("g", now: t.addingTimeInterval(2))
    XCTAssertNil(q.next(now: t.addingTimeInterval(5)))
    XCTAssertEqual(q.next(now: t.addingTimeInterval(6)), "g")
    q.enqueue("g", now: t.addingTimeInterval(7))
    XCTAssertNil(q.next(now: t.addingTimeInterval(20)))
    q.complete()
    XCTAssertEqual(q.next(now: t.addingTimeInterval(20)), "g")
    q.complete()
    XCTAssertNil(q.next(now: t.addingTimeInterval(30)))
  }
  func testQueueMaxWaitAndFairness() {
    var q = AnalysisQueue()
    let t = Date(timeIntervalSince1970: 0)
    for n in 0...14 { q.enqueue("g", now: t.addingTimeInterval(Double(n))) }
    q.enqueue("h", now: t.addingTimeInterval(14))
    XCTAssertEqual(q.next(now: t.addingTimeInterval(15)), "g")
    q.complete()
    XCTAssertEqual(q.next(now: t.addingTimeInterval(18)), "h")
  }
  func testCatalogURLPreservesQuery() {
    let u = try! ModelCatalog.requestURL(
      URL(string: "https://cpa.bgp.kiliter.cn/v1/models?route=a&client_version=old")!)
    let q = URLComponents(url: u, resolvingAgainstBaseURL: false)!.queryItems!
    XCTAssertEqual(q.filter { $0.name == "client_version" }.count, 1)
    XCTAssertTrue(q.contains { $0.name == "route" && $0.value == "a" })
  }
  func testNativeCatalogCapabilities() throws {
    let json =
      #"{"models":[{"slug":"test","display_name":"测试","context_window":32768,"max_context_window":65536,"max_tokens":4096,"effective_context_window_percent":90,"supported_reasoning_levels":[{"effort":"low"}],"supported_in_api":true},{"slug":"hidden","visibility":"hide"}]}"#
    let m = try ModelCatalog.parse(Data(json.utf8))
    XCTAssertEqual(m.count, 1)
    XCTAssertEqual(m[0].context, 32768)
    XCTAssertEqual(m[0].reasoningLevels, ["low"])
    XCTAssertLessThanOrEqual(m[0].inputBudget, 24000)
  }
  func testStandardCatalogDoesNotInventContext() throws {
    let m = try ModelCatalog.parse(Data(#"{"data":[{"id":"plain"}]}"#.utf8))
    XCTAssertNil(m[0].context)
    XCTAssertFalse(m[0].native)
  }
  func testLargeCatalogContextDoesNotOverflowBudgetCalculation() throws {
    let data = try JSONSerialization.data(withJSONObject: ["models": [["slug": "large",
      "context_window": Int.max, "effective_context_window_percent": 95, "max_tokens": 4096]]])
    let model = try XCTUnwrap(ModelCatalog.parse(data).first)
    XCTAssertEqual(model.context, Int.max)
    XCTAssertEqual(model.inputBudget, 24_000)
  }
  func testSSEMultilineAndReset() {
    var p = SSEParser()
    XCTAssertNil(p.consume(": keepalive"))
    XCTAssertNil(p.consume("event: message.new"))
    XCTAssertNil(p.consume("data: hello"))
    XCTAssertNil(p.consume("data: world"))
    XCTAssertEqual(p.consume("")?.data, "hello\nworld")
    XCTAssertNil(p.consume(""))
    _ = p.consume("data: next")
    XCTAssertEqual(p.consume("")?.event, "message")
  }
  func testPushRejectsWrongAccount() {
    let json =
      #"{"accountId":"other","sessionId":"g","id":"1","sent_at_unix_ms":"100","text":"test"}"#
    XCTAssertNil(PushMessage.decode(Data(json.utf8), account: "me"))
  }
  func response(_ output: String, status: String = "completed") throws -> Data {
    try JSONSerialization.data(withJSONObject: [
      "status": status, "output": [["content": [["type": "output_text", "text": output]]]],
    ])
  }
  func testAIRequiresGroundedEvidence() throws {
    let good =
      #"{"summary":"相关摘要","relevant":true,"relevanceReason":"明确问我","evidenceIDs":["1"],"judgements":[]}"#
    XCTAssertTrue(try CPAClient.parseResponse(response(good), allowedIDs: ["1"]).relevant)
    XCTAssertThrowsError(try CPAClient.parseResponse(response(good), allowedIDs: ["2"]))
    XCTAssertThrowsError(
      try CPAClient.parseResponse(response(good, status: "incomplete"), allowedIDs: ["1"]))
  }
  func testUnrelatedSummaryCanBeStoredButNotRelated() throws {
    let json =
      #"{"summary":"普通闲聊","relevant":false,"relevanceReason":"无关","evidenceIDs":[],"judgements":[]}"#
    XCTAssertFalse(try CPAClient.parseResponse(response(json), allowedIDs: []).relevant)
  }
  func testStateRoundTripPreservesProgressAndSnooze() throws {
    var s = AppSnapshot()
    s.preferences.names = ["嘉林"]
    s.checkpoints["a|g"] = Checkpoint(after: 900, cursor: "next", upper: 1000)
    s.seen.insert("a|g|42")
    s.pendingAI.insert("a|g|42")
    var item = Attention(
      message: message("测试"), groupName: "测试群", title: "找我", reason: "命中", definite: true)
    item.status = "snoozed"
    item.remindAt = Date(timeIntervalSince1970: 200)
    s.attentions = [item]
    let restored = try JSONDecoder().decode(AppSnapshot.self, from: JSONEncoder().encode(s))
    XCTAssertEqual(restored.checkpoints["a|g"]?.cursor, "next")
    XCTAssertEqual(restored.attentions[0].status, "snoozed")
    XCTAssertEqual(restored.pendingAI, s.pendingAI)
  }
  func testContradictoryRelevanceRejected() throws {
    let text =
      #"{"summary":"无关闲聊","relevant":false,"relevanceReason":"无关","evidenceIDs":[],"judgements":[{"messageID":"1","needsResponse":true,"confidence":"high","title":"回复","reason":"有人找我"}]}"#
    XCTAssertThrowsError(try CPAClient.parseResponse(response(text), allowedIDs: ["1"]))
  }
  func testUnreadBootstrapCanResume() throws {
    let checkpoint = Checkpoint(
      after: 900, cursor: "older-page", upper: 1000, baseline: true, remaining: 450)
    let restored = try JSONDecoder().decode(Checkpoint.self, from: JSONEncoder().encode(checkpoint))
    XCTAssertTrue(restored.baseline)
    XCTAssertEqual(restored.remaining, 450)
    XCTAssertEqual(restored.upper, 1000)
  }

}
