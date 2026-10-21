import XCTest
@testable import QundaoCore

private final class JevStub: URLProtocol {
  static var responder: ((URLRequest) throws -> (Int, Data))?
  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
  override func startLoading() {
    do {
      let (status, data) = try Self.responder!(request)
      client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status,
        httpVersion: nil, headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
      client?.urlProtocol(self, didLoad: data)
      client?.urlProtocolDidFinishLoading(self)
    } catch { client?.urlProtocol(self, didFailWithError: error) }
  }
  override func stopLoading() {}
}
final class JevTransportTests: XCTestCase {
  private func sample() -> Message {
    Message(id: "1", accountID: "test", groupID: "g", senderID: "other", sender: "测试同事",
            text: "请帮忙看一下发布", timestamp: 1)
  }
  private func client() -> JevClient {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [JevStub.self]
    return JevClient(key: "synthetic-test-key", session: URLSession(configuration: config))
  }
  func testOfficialTransportAndTypedDecision() async throws {
    JevStub.responder = { request in
      XCTAssertEqual(request.url?.absoluteString, "https://api.typesafe.ai/v1/systemone")
      XCTAssertEqual(request.httpMethod, "POST")
      XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer synthetic-test-key")
      return (200, Data(#"{"model":"jev-latest","answers":{"related_0":{"type":"noul","noul":0.9},"response_0":{"type":"noul","noul":0.8}}}"#.utf8))
    }
    let results = try await client().decide(messages: [sample()], context: [], names: ["测试用户"], keywords: [], selfID: "me")
    XCTAssertEqual(results.first?.needsResponse, 0.8)
  }
  func testServiceFailureProducesSafeFallbackError() async throws {
    JevStub.responder = { _ in (503, Data("不要向日志输出的服务正文".utf8)) }
    do {
      _ = try await client().decide(messages: [sample()], context: [], names: [], keywords: [], selfID: "me")
      XCTFail("服务失败不能返回成功决策")
    } catch {
      XCTAssertTrue(error.localizedDescription.contains("503"))
      XCTAssertTrue(error.localizedDescription.contains("本地识别继续工作"))
      XCTAssertFalse(error.localizedDescription.contains("不要向日志输出"))
    }
  }
  func testOpenRouterTransportAndDiagnosticsCaptureTypedIO() async throws {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [JevStub.self]
    var records: [DiagnosticRecord] = []
    JevStub.responder = { request in
      XCTAssertEqual(request.url?.absoluteString, "https://openrouter.ai/api/alpha/decisions")
      return (200, Data(#"{"answers":{"related_0":{"type":"noul","noul":0.9},"response_0":{"type":"noul","noul":0.8}}}"#.utf8))
    }
    let client = JevClient(key: "synthetic-key", configuration: .openRouter,
      session: URLSession(configuration: config), trace: { records.append($0) })
    _ = try await client.decide(messages: [sample()], context: [], names: [], keywords: [], selfID: "me")
    XCTAssertEqual(records.map(\.event), ["请求开始", "决策完成"])
    XCTAssertEqual(records[0].correlationID, records[1].correlationID)
    XCTAssertTrue(records[0].input.contains("~typesafe/jev-latest"))
    XCTAssertTrue(records[0].input.contains("请帮忙看一下发布"))
    XCTAssertTrue(records[1].output.contains("0.9"))
    XCTAssertFalse(records[0].input.contains("synthetic-key"))
  }
  func testCPAInvalidOutputRetainsDiagnosticsAndDoesNotSucceed() async throws {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [JevStub.self]
    var records: [DiagnosticRecord] = []
    JevStub.responder = { _ in (200, Data(#"{"status":"incomplete","echo":"synthetic-key"}"#.utf8)) }
    let model = try ModelCatalog.parse(Data(#"{"data":[{"id":"test-model"}]}"#.utf8))[0]
    let client = CPAClient(key: "synthetic-key", session: URLSession(configuration: config), trace: { records.append($0) })
    do {
      _ = try await client.analyze(messages: [sample()], context: [], priorSummary: "", names: [], keywords: [], selfID: "me", model: model, reasoning: "")
      XCTFail("不完整输出不能成功")
    } catch {
      XCTAssertEqual(records.map(\.event), ["请求开始", "摘要失败"])
      XCTAssertTrue(records[1].output.contains("incomplete"))
      XCTAssertFalse(records[1].output.contains("synthetic-key"))
      XCTAssertTrue(records[1].error.contains("未完成"))
      XCTAssertEqual(records[1].statusCode, 200)
    }
  }

}
