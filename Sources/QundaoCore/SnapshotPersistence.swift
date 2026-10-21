import Foundation
import Darwin

/// 临时文件先以 600 权限写全并同步，再用同目录 rename 原子提交。
/// 所有会抛错的准备操作均在提交前，避免标记已经替换后再因 chmod 报失败。
public struct SnapshotPersistence {
  public let directory: URL
  public init(directory: URL) { self.directory = directory }
  public func load() throws -> AppSnapshot {
    let file = directory.appendingPathComponent("state.json")
    guard FileManager.default.fileExists(atPath: file.path) else { return AppSnapshot() }
    return try JSONDecoder().decode(AppSnapshot.self, from: Data(contentsOf: file))
  }
  public func save(_ snapshot: AppSnapshot) throws {
    let data = try JSONEncoder().encode(snapshot)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    let temporary = directory.appendingPathComponent(".state-\(UUID().uuidString).tmp")
    let fd = Darwin.open(temporary.path, O_WRONLY | O_CREAT | O_EXCL, mode_t(0o600))
    guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    defer { try? handle.close(); try? FileManager.default.removeItem(at: temporary) }
    try handle.write(contentsOf: data)
    try handle.synchronize()
    try handle.close()
    let destination = directory.appendingPathComponent("state.json")
    guard Darwin.rename(temporary.path, destination.path) == 0 else {
      throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
    // rename 已完成即为提交成功；同步目录减少突然掉电丢失目录项的窗口。
    let directoryFD = Darwin.open(directory.path, O_RDONLY)
    if directoryFD >= 0 { _ = Darwin.fsync(directoryFD); Darwin.close(directoryFD) }
  }
}
