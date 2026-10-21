import XCTest
@testable import QundaoCore

@MainActor private final class GroupResponseGate {
  var requests: [(String, CheckedContinuation<[ChatGroup], Error>)] = []
  func load(_ account: String) async throws -> [ChatGroup] {
    try await withCheckedThrowingContinuation { requests.append((account, $0)) }
  }
  func succeed(_ index: Int, unread: Int) {
    requests[index].1.resume(returning: [ChatGroup(id: "g", name: "群", unread: unread)])
  }
}

@MainActor final class GroupStateSynchronizerTests: XCTestCase {
  private func settle(_ predicate: () -> Bool) async {
    for _ in 0..<1000 {
      if predicate() { return }
      try? await Task.sleep(nanoseconds: 1_000_000)
    }
    XCTFail("等待群状态请求超时")
  }

  func testUnreadTransitionsRefreshWithoutMessagesOrListeningState() async throws {
    var unread = 5
    let sync = GroupStateSynchronizer(account: "a", load: { _ in
      [ChatGroup(id: "g", name: "群", unread: unread)]
    })
    _ = try await sync.refresh(account: "a")
    XCTAssertEqual(sync.state.groups.first?.unread, 5)
    unread = 0
    _ = try await sync.refresh(account: "a")
    XCTAssertEqual(sync.state.groups.first?.unread, 0)
    unread = 3
    _ = try await sync.refresh(account: "a")
    XCTAssertEqual(sync.state.groups.first?.unread, 3)
    XCTAssertNotNil(sync.state.lastSync)
    XCTAssertNil(sync.state.error)
  }

  func testForegroundPeriodicAndBackfillReadersShareOneRequest() async throws {
    let gate = GroupResponseGate()
    let sync = GroupStateSynchronizer(account: "a", load: gate.load)
    var committed = 0
    sync.changed = { if $0.lastSync != nil && !$0.refreshing { committed += 1 } }
    let first = Task { try await sync.refresh(account: "a") }
    await settle { gate.requests.count == 1 }
    var joined = 0
    let second = Task { joined += 1; return try await sync.refresh(account: "a") }
    let third = Task { joined += 1; return try await sync.refresh(account: "a") }
    await settle { joined == 2 }
    XCTAssertTrue(sync.state.refreshing)
    XCTAssertEqual(gate.requests.count, 1)
    gate.succeed(0, unread: 0)
    let results = try await [first.value, second.value, third.value]
    XCTAssertEqual(results.map { $0.first?.unread }, [0, 0, 0])
    XCTAssertEqual(committed, 1)
    XCTAssertFalse(sync.state.refreshing)
  }

  func testAccountSwitchDropsLateResponseEvenWhenTransportIgnoresCancellation() async throws {
    let gate = GroupResponseGate()
    let sync = GroupStateSynchronizer(account: "a", load: gate.load)
    let old = Task { try await sync.refresh(account: "a") }
    await settle { gate.requests.count == 1 }
    sync.reset(account: "b")
    XCTAssertTrue(sync.state.groups.isEmpty)
    XCTAssertNil(sync.state.lastSync)
    let current = Task { try await sync.refresh(account: "b") }
    await settle { gate.requests.count == 2 }
    gate.succeed(1, unread: 0)
    _ = try await current.value
    gate.succeed(0, unread: 99)
    do { _ = try await old.value; XCTFail("旧账号响应应被丢弃") } catch is CancellationError {} catch { XCTFail("错误类型不符") }
    XCTAssertEqual(sync.state.account, "b")
    XCTAssertEqual(sync.state.groups.first?.unread, 0)
    XCTAssertNil(sync.state.error)
  }

  func testSameAccountGenerationRejectsStaleResponseAfterReconnection() async throws {
    let gate = GroupResponseGate()
    let sync = GroupStateSynchronizer(account: "a", load: gate.load)
    let old = Task { try await sync.refresh(account: "a") }
    await settle { gate.requests.count == 1 }
    sync.reset(account: "a")
    let current = Task { try await sync.refresh(account: "a") }
    await settle { gate.requests.count == 2 }
    gate.succeed(1, unread: 0)
    _ = try await current.value
    gate.succeed(0, unread: 8)
    do { _ = try await old.value; XCTFail("旧代次响应应被丢弃") } catch is CancellationError {} catch { XCTFail("错误类型不符") }
    XCTAssertEqual(sync.state.groups.first?.unread, 0)
  }

  func testFailureRetainsLastSuccessfulCountsAndTimeThenRetryClearsError() async throws {
    var failure = false, clock = Date(timeIntervalSince1970: 100)
    let sync = GroupStateSynchronizer(account: "a", now: { clock }, load: { _ in
      if failure { throw AppFailure.message("Alpha 暂时离线") }
      return [ChatGroup(id: "g", name: "群", unread: 4)]
    })
    _ = try await sync.refresh(account: "a")
    failure = true; clock = Date(timeIntervalSince1970: 200)
    do { _ = try await sync.refresh(account: "a"); XCTFail("应报告离线") } catch {}
    XCTAssertEqual(sync.state.groups.first?.unread, 4)
    XCTAssertEqual(sync.state.lastSync, Date(timeIntervalSince1970: 100))
    XCTAssertNotNil(sync.state.error)
    XCTAssertFalse(sync.state.refreshing)
    failure = false
    _ = try await sync.refresh(account: "a")
    XCTAssertNil(sync.state.error)
    XCTAssertEqual(sync.state.lastSync, clock)
  }

  func testCachedCountsAreNotPresentedAsAlreadySynchronizedAndCancelKeepsThem() async throws {
    let gate = GroupResponseGate()
    let sync = GroupStateSynchronizer(account: "a", cachedGroups: [ChatGroup(id: "g", name: "群", unread: 2)], load: gate.load)
    XCTAssertNil(sync.state.lastSync)
    let task = Task { try await sync.refresh(account: "a") }
    await settle { gate.requests.count == 1 }
    sync.cancel()
    XCTAssertEqual(sync.state.groups.first?.unread, 2)
    XCTAssertFalse(sync.state.refreshing)
    gate.succeed(0, unread: 0)
    do { _ = try await task.value; XCTFail("取消后的响应应被丢弃") } catch is CancellationError {} catch { XCTFail("错误类型不符") }
    XCTAssertEqual(sync.state.groups.first?.unread, 2)
    XCTAssertNil(sync.state.lastSync)
  }
}
