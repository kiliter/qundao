import XCTest
@testable import QundaoCore

/// 同群摘要覆盖与提醒并入规则。
final class DigestCoverageTests: XCTestCase {
  private func msg(_ n: Int, group: String = "g", account: String = "a") -> Message {
    Message(id: "M\(n)", accountID: account, groupID: group, senderID: "s", sender: "同事", text: "合成\(n)",
            timestamp: Int64(n) * 1000)
  }
  private func digest(_ range: ClosedRange<Int>, group: String = "g", account: String = "a", related: Bool = true) -> Digest {
    Digest(accountID: account, groupID: group, groupName: "群", text: "摘要\(range)", count: range.count,
           evidence: range.map { msg($0, group: group, account: account) }, related: related, relevanceReason: "")
  }

  func testNewerSupersetCoversOlderAndOnlyLatestIsPending() {
    var digests = [digest(1...3), digest(1...5)]
    XCTAssertEqual(DigestCoverage.apply(&digests), 1)
    XCTAssertEqual(digests[0].supersededBy, digests[1].id)
    let entries = AttentionFeed.entries(attentions: [], digests: digests, account: "a")
    XCTAssertEqual(entries.map(\.id), ["summary|\(digests[1].id.uuidString)"])
    // 历史中仍保留，但不计待阅。
    let history = AttentionFeed.threads(attentions: [], digests: digests, account: "a", includeHistory: true)
    XCTAssertEqual(history.first?.entries.count, 2)
    XCTAssertEqual(history.first?.pendingCount, 1)
    // 幂等。
    XCTAssertEqual(DigestCoverage.apply(&digests), 0)
  }

  func testChainPointsToLatestAndPartialOverlapStaysSeparate() {
    var chain = [digest(1...2), digest(1...4), digest(1...6)]
    DigestCoverage.apply(&chain)
    XCTAssertEqual(chain[0].supersededBy, chain[2].id)
    XCTAssertEqual(chain[1].supersededBy, chain[2].id)
    // 期间在微信读过：新摘要只含 M4–M6，与旧摘要不是包含关系，两条并列。
    var partial = [digest(1...3), digest(4...6)]
    XCTAssertEqual(DigestCoverage.apply(&partial), 0)
    XCTAssertEqual(AttentionFeed.entries(attentions: [], digests: partial, account: "a").count, 2)
  }

  func testUnrelatedNewerReadOlderAndOtherScopesDoNotSupersede() {
    var unrelated = [digest(1...3), digest(1...5, related: false)]
    XCTAssertEqual(DigestCoverage.apply(&unrelated), 0, "新摘要判为无关时不能藏起旧的相关摘要")
    var read = [digest(1...3), digest(1...5)]
    read[0].attentionReadAt = Date(timeIntervalSince1970: 1)
    XCTAssertEqual(DigestCoverage.apply(&read), 0)
    var scopes = [digest(1...3), digest(1...5, group: "h"), digest(1...5, account: "b")]
    XCTAssertEqual(DigestCoverage.apply(&scopes), 0)
  }

  func testCoveredResponseBecomesTagAndPendingResponseIsNeverHidden() {
    var digests = [digest(1...5)]
    let inside = Attention(message: msg(4), groupName: "群", title: "同事 找你", reason: "@我", definite: true)
    let outside = Attention(message: msg(9), groupName: "群", title: "同事 可能需要你回应", reason: "Jev", definite: false)
    let threads = AttentionFeed.threads(attentions: [inside, outside], digests: digests, account: "a")
    XCTAssertEqual(threads.first?.entries.count, 2, "证据外的提醒仍单独成条")
    let summary = threads.first!.entries.first { !$0.isResponse }!
    XCTAssertEqual(threads.first?.tags(for: summary).map(\.id), [inside.id])
    // 摘要已阅后，仍待阅的提醒不能挂在已阅摘要下被藏起。
    digests[0].attentionReadAt = Date()
    let after = AttentionFeed.entries(attentions: [inside], digests: digests, account: "a")
    XCTAssertEqual(after.map(\.id), ["response|\(inside.id)"])
  }

  func testLegacyDigestWithoutSupersededFieldDecodes() throws {
    let old = digest(1...2)
    var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(old)) as? [String: Any])
    json.removeValue(forKey: "supersededBy")
    let restored = try JSONDecoder().decode(Digest.self, from: JSONSerialization.data(withJSONObject: json))
    XCTAssertNil(restored.supersededBy)
    var snapshot = AppSnapshot()
    snapshot.digests = [restored, digest(1...4)]
    XCTAssertEqual(snapshot.migrateDigestCoverage(), 1)
    XCTAssertEqual(snapshot.migrateDigestCoverage(), 0)
  }
}
