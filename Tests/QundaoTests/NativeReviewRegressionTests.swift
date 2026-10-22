import Foundation
import QundaoCore
import XCTest
@testable import Qundao

final class NotificationRoutingTests: XCTestCase {
  func testOldAccountNotificationCannotOpenItsTranscriptAfterSwitchingAccounts() {
    let old = attention(account: "account-a")
    let current = attention(account: "account-b")
    XCTAssertNil(NotificationRouting.attention(id: old.id, records: [old, current], accountID: "account-b"))
    XCTAssertEqual(NotificationRouting.attention(id: current.id, records: [old, current], accountID: "account-b"), current)
    XCTAssertNil(NotificationRouting.attention(id: old.id, records: [old], accountID: ""))
    XCTAssertNil(NotificationRouting.attention(id: nil, records: [old], accountID: "account-a"))
  }

  private func attention(account: String) -> Attention {
    Attention(message: Message(id: "m1", accountID: account, groupID: "group", senderID: "peer",
      sender: "测试同事", text: "合成通知正文", timestamp: 1), groupName: "测试群", title: "找你",
      reason: "合成命中", definite: true)
  }
}

final class LogBrowserTests: XCTestCase {
  @MainActor
  func testResumingSubscriptionKeepsHistoryPageAndSelectedDetail() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let archive = DiagnosticLogStore(directory: directory)
    for index in 0..<4 { try archive.append(record(index)) }
    let browser = LogBrowser(archive: archive)
    browser.pageSize = 2
    await browser.first()
    await browser.next()
    let selected = browser.selected?.id
    let rows = browser.rows.map(\.id)
    try archive.append(record(4))

    let subscription = Task { await browser.observeUpdates() }
    await eventually { browser.latestRevision == archive.revision }
    XCTAssertEqual(browser.pageIndex, 1)
    XCTAssertEqual(browser.rows.map(\.id), rows)
    XCTAssertEqual(browser.selected?.id, selected)
    XCTAssertTrue(browser.hasNewRecords)
    subscription.cancel()
    await subscription.value
  }

  @MainActor
  func testResumingPausedLiveReadingDoesNotRefreshUntilRequested() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let archive = DiagnosticLogStore(directory: directory)
    try archive.append(record(0))
    let browser = LogBrowser(archive: archive)
    await browser.first()
    let selected = browser.selected?.id
    browser.live = false
    try archive.append(record(1))

    let subscription = Task { await browser.observeUpdates() }
    await eventually { browser.latestRevision == archive.revision }
    XCTAssertEqual(browser.rows.count, 1)
    XCTAssertEqual(browser.selected?.id, selected)
    XCTAssertTrue(browser.hasNewRecords)
    subscription.cancel()
    await subscription.value
  }

  @MainActor
  func testLiveLatestPageRefreshesButKeepsChosenDetailAndCancellationStopsUpdates() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let archive = DiagnosticLogStore(directory: directory)
    try archive.append(record(0))
    let browser = LogBrowser(archive: archive)
    await browser.first()
    let selected = browser.selected?.id
    browser.choose(selected)
    let subscription = Task { await browser.observeUpdates() }
    try archive.append(record(1))
    await eventually { browser.rows.count == 2 }
    XCTAssertEqual(browser.selected?.id, selected)
    XCTAssertFalse(browser.following)
    subscription.cancel()
    await subscription.value
    try archive.append(record(2))
    XCTAssertEqual(browser.rows.count, 2)
  }

  private func record(_ index: Int) -> DiagnosticRecord {
    DiagnosticRecord(category: .runtime, event: "合成日志 \(index)")
  }

  @MainActor private func eventually(_ condition: () -> Bool, file: StaticString = #filePath,
                                     line: UInt = #line) async {
    for _ in 0..<100 {
      if condition() { return }
      try? await Task.sleep(nanoseconds: 10_000_000)
    }
    XCTFail("等待日志状态更新超时", file: file, line: line)
  }
}
