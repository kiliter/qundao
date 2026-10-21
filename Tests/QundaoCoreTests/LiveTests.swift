import XCTest

@testable import QundaoCore

final class LiveTests: XCTestCase {
  func testCPACatalogAndSyntheticAnalysis() async throws {
    guard let key = ProcessInfo.processInfo.environment["QUNDAO_TEST_CPA_KEY"] else {
      throw XCTSkip("未启用真实 CPA 验证")
    }
    let client = CPAClient(key: key)
    let models = try await client.catalog()
    XCTAssertFalse(models.isEmpty)
    guard let model = models.first(where: { $0.id == "gpt-6.1-sol" }) ?? models.first else {
      XCTFail()
      return
    }
    XCTAssertNotNil(model.context)
    let message = Message(
      id: "test-1", accountID: "synthetic", groupID: "demo@chatroom", senderID: "colleague",
      sender: "测试同事", text: "@测试用户 请帮忙确认测试项目明天的验收时间。", timestamp: 1)
    let result = try await client.analyze(
      messages: [message], context: [], priorSummary: "", names: ["测试用户"], keywords: ["验收"],
      selfID: "test-user", model: model, reasoning: "low")
    XCTAssertFalse(result.summary.isEmpty)
    XCTAssertTrue(result.relevant)
  }
  func testAlphaReadOnlyConnection() async throws {
    guard let token = ProcessInfo.processInfo.environment["QUNDAO_TEST_ALPHA_TOKEN"] else {
      throw XCTSkip("未启用真实 Alpha 验证")
    }
    let client = AlphaClient(token: token)
    let accounts = try await client.accounts()
    XCTAssertFalse(accounts.isEmpty)
    if let account = accounts.first {
      let groups = try await client.groups(account: account.id)
      XCTAssertFalse(groups.isEmpty)
    }
  }
  func testAlphaCompleteUnreadSnapshotReadOnly() async throws {
    guard let token = ProcessInfo.processInfo.environment["QUNDAO_TEST_ALPHA_TOKEN"] else { throw XCTSkip("未启用真实 Alpha 快照验证") }
    let client = AlphaClient(token: token)
    guard let account = try await client.accounts().first else { throw XCTSkip("没有可用账号") }
    let groups = try await client.groups(account: account.id)
    let allowed = Set((ProcessInfo.processInfo.environment["QUNDAO_TEST_ALPHA_GROUPS"] ?? "").split(separator: ",").map(String.init))
    guard let group = groups.filter({ allowed.contains($0.id) && $0.unread > 1 && $0.unread <= 50 }).sorted(by: { $0.unread < $1.unread }).first else {
      throw XCTSkip("当前没有适合只读分页验证的未读群")
    }
    struct SmallPages: UnreadSource {
      let client: AlphaClient
      func unreadGroup(_ scope: ConversationScope) async throws -> ChatGroup { try await client.unreadGroup(scope) }
      func unreadPage(_ scope: ConversationScope, before: Int64?, cursor: String?, limit: Int) async throws -> MessagePage {
        try await client.unreadPage(scope, before: before, cursor: cursor, limit: min(2, limit))
      }
    }
    let scope = ConversationScope(account: account.id, group: group.id)
    let snapshot = try await UnreadSnapshotLoader(source: SmallPages(client: client)).load(scope)
    XCTAssertFalse(snapshot.messages.isEmpty)
    XCTAssertEqual(Set(snapshot.messages.map(\.id)).count, snapshot.messages.count)
    let head = try await UnreadSnapshotLoader(source: client).head(scope)
    XCTAssertEqual(snapshot.messages.last?.id, head?.lastID)
    XCTAssertEqual(snapshot.messages.count, head?.count)
  }
  func testRealPushShape() {
    let json =
      #"{"accountId":"a","rawid":"1234567890123456789","sessionId":"g@chatroom","sessionType":"group","sourceName":"测试同事","groupName":"测试群","content":"@测试用户 确认一下","timestamp":1792560000}"#
    let m = PushMessage.decode(Data(json.utf8), account: "a")
    XCTAssertEqual(m?.id, "1234567890123456789")
    XCTAssertEqual(m?.timestamp, 1_792_560_000_000)
    XCTAssertEqual(m?.sender, "测试同事")
  }
}
