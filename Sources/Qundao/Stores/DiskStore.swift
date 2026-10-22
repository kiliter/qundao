import Foundation
import QundaoCore

/// 持有同一个数据库连接与增量基准；只在主线程使用。
final class DiskStore {
  let directory: URL
  init(directory: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    .appendingPathComponent("Qundao", isDirectory: true)) {
    self.directory = directory
  }
  private lazy var persistence = SnapshotPersistence(directory: directory)
  func load() throws -> AppSnapshot { try persistence.load() }
  func save(_ state: AppSnapshot) throws { try persistence.save(state) }
}
