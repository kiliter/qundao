import Foundation

/// 每个群只有一个等待槽位；执行期间到达的消息形成下一批。
public struct AnalysisQueue {
  public struct Slot {
    public var first: Date
    public var last: Date
    public var urgent: Bool
  }
  public private(set) var waiting: [String: Slot] = [:]
  public private(set) var inFlight: String?
  public let debounce: TimeInterval
  public let maxWait: TimeInterval
  public init(debounce: TimeInterval = 4, maxWait: TimeInterval = 15) {
    self.debounce = debounce
    self.maxWait = maxWait
  }
  public mutating func enqueue(_ group: String, now: Date = Date(), urgent: Bool = false) {
    if var slot = waiting[group] {
      slot.last = now
      slot.urgent = slot.urgent || urgent
      waiting[group] = slot
    } else {
      waiting[group] = Slot(first: now, last: now, urgent: urgent)
    }
  }
  public mutating func next(now: Date = Date()) -> String? {
    guard inFlight == nil else { return nil }
    let ready = waiting.filter {
      $0.value.urgent || now.timeIntervalSince($0.value.last) >= debounce
        || now.timeIntervalSince($0.value.first) >= maxWait
    }.sorted { $0.value.first < $1.value.first }
    guard let key = ready.first?.key else { return nil }
    waiting[key] = nil
    inFlight = key
    return key
  }
  public mutating func complete() { inFlight = nil }
  public mutating func reset() {
    waiting = [:]
    inFlight = nil
  }
}
