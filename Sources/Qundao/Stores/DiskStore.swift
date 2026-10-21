import Foundation
import QundaoCore

struct DiskStore {
  let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    .appendingPathComponent("Qundao", isDirectory: true)
  func load() throws -> AppSnapshot { try SnapshotPersistence(directory: directory).load() }
  func save(_ state: AppSnapshot) throws { try SnapshotPersistence(directory: directory).save(state) }
}
