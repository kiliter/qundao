import Foundation

/// Alpha 的会话状态独立于消息补查和摘要进度，同一账号共享一次正在进行的读取。
@MainActor public final class GroupStateSynchronizer {
  public struct State {
    public var account: String
    public var groups: [ChatGroup]
    public var lastSync: Date?
    public var error: String?
    public var refreshing = false
  }
  public private(set) var state: State
  public var changed: ((State) -> Void)?
  private let load: (String) async throws -> [ChatGroup]
  private let now: () -> Date
  private var generation = UUID()
  private var request: UInt64 = 0
  private var inFlight: (id: UInt64, task: Task<[ChatGroup], Error>)?

  public init(account: String = "", cachedGroups: [ChatGroup] = [],
              now: @escaping () -> Date = Date.init,
              load: @escaping (String) async throws -> [ChatGroup]) {
    state = State(account: account, groups: cachedGroups)
    self.now = now
    self.load = load
  }

  public func reset(account: String, cachedGroups: [ChatGroup] = []) {
    invalidate()
    state = State(account: account, groups: cachedGroups)
    changed?(state)
  }

  /// 取消当前读取，保留最近一次成功状态；迟到的响应不能再提交。
  public func cancel() {
    invalidate()
    state.refreshing = false
    changed?(state)
  }

  private func invalidate() {
    generation = UUID()
    inFlight?.task.cancel()
    inFlight = nil
  }

  public func refresh(account: String) async throws -> [ChatGroup] {
    guard !account.isEmpty, account == state.account else { throw CancellationError() }
    let current = generation
    let operation: (id: UInt64, task: Task<[ChatGroup], Error>)
    if let inFlight {
      operation = inFlight
    } else {
      request &+= 1
      operation = (request, Task { try await load(account) })
      inFlight = operation
      state.refreshing = true
      changed?(state)
    }
    do {
      let groups = try await operation.task.value
      guard current == generation, account == state.account, operation.id == request else {
        throw CancellationError()
      }
      if inFlight?.id == operation.id {
        inFlight = nil
        state.groups = groups
        state.lastSync = now()
        state.error = nil
        state.refreshing = false
        changed?(state)
      }
      return groups
    } catch {
      if current == generation, account == state.account, inFlight?.id == operation.id {
        inFlight = nil
        state.refreshing = false
        if !(error is CancellationError) { state.error = error.localizedDescription }
        changed?(state)
      }
      throw error
    }
  }
}
