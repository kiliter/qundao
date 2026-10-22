import Foundation
import XCTest
@testable import Qundao

final class ConfigWatcherTests: XCTestCase {
  @MainActor
  func testInPlaceEditAndAtomicReplacementBothReload() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("qundao-watcher-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("config.toml")
    try Data("旧配置".utf8).write(to: url)
    let first = expectation(description: "原地写入触发重载")
    let second = expectation(description: "原子替换触发重载")
    let third = expectation(description: "替换后的新文件仍可监听原地写入")
    var observed: Set<String> = []
    let watcher = try XCTUnwrap(ConfigWatcher(url: url) {
      guard let value = try? String(contentsOf: url), observed.insert(value).inserted else { return }
      switch value {
      case "原地修改": first.fulfill()
      case "原子替换": second.fulfill()
      case "再次修改": third.fulfill()
      default: break
      }
    })
    func overwrite(_ text: String) throws {
      let handle = try FileHandle(forWritingTo: url)
      defer { try? handle.close() }
      try handle.truncate(atOffset: 0)
      try handle.write(contentsOf: Data(text.utf8))
      try handle.synchronize()
    }
    try overwrite("原地修改")
    await fulfillment(of: [first], timeout: 2)
    try Data("原子替换".utf8).write(to: url, options: .atomic)
    await fulfillment(of: [second], timeout: 2)
    try overwrite("再次修改")
    await fulfillment(of: [third], timeout: 2)
    withExtendedLifetime(watcher) {}
  }
}
