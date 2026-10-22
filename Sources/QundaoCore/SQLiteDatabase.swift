import Foundation
import SQLite3

/// 系统自带 SQLite 的最小封装：统一参数绑定、错误与事务。只在单一线程（主线程）上使用。
final class SQLiteDatabase {
  private var handle: OpaquePointer?
  private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
  init(path: String) throws {
    guard sqlite3_open_v2(path, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK else {
      let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "未知错误"
      sqlite3_close(handle); handle = nil
      throw AppFailure.message("本地数据库无法打开：\(message)")
    }
    sqlite3_busy_timeout(handle, 3000)
  }
  deinit { sqlite3_close(handle) }
  var errorMessage: String { handle.map { String(cString: sqlite3_errmsg($0)) } ?? "数据库未打开" }

  func execute(_ sql: String) throws {
    guard sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK else {
      throw AppFailure.message("本地数据库执行失败：\(errorMessage)")
    }
  }
  enum Value { case text(String), blob(Data), int(Int64), null }
  /// 执行一条带参数的语句；有结果行时逐行回调。
  func run(_ sql: String, _ values: [Value] = [], row: ((OpaquePointer) throws -> Void)? = nil) throws {
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
      throw AppFailure.message("本地数据库语句无效：\(errorMessage)")
    }
    defer { sqlite3_finalize(statement) }
    for (offset, value) in values.enumerated() {
      let index = Int32(offset + 1)
      switch value {
      case .text(let text): sqlite3_bind_text(statement, index, text, -1, Self.transient)
      case .blob(let data):
        _ = data.withUnsafeBytes { sqlite3_bind_blob(statement, index, $0.baseAddress, Int32(data.count), Self.transient) }
      case .int(let number): sqlite3_bind_int64(statement, index, number)
      case .null: sqlite3_bind_null(statement, index)
      }
    }
    while true {
      let result = sqlite3_step(statement)
      if result == SQLITE_DONE { return }
      guard result == SQLITE_ROW else { throw AppFailure.message("本地数据库写入失败：\(errorMessage)") }
      try row?(statement)
    }
  }
  /// 整体成功才提交；任一步失败回滚，磁盘保持上一次提交的状态。
  func transaction(_ body: () throws -> Void) throws {
    try execute("BEGIN IMMEDIATE")
    do { try body(); try execute("COMMIT") }
    catch { try? execute("ROLLBACK"); throw error }
  }
  static func text(_ statement: OpaquePointer, _ column: Int32) -> String {
    sqlite3_column_text(statement, column).map { String(cString: $0) } ?? ""
  }
  static func blob(_ statement: OpaquePointer, _ column: Int32) -> Data {
    guard let bytes = sqlite3_column_blob(statement, column) else { return Data() }
    return Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, column)))
  }
  static func int(_ statement: OpaquePointer, _ column: Int32) -> Int64 { sqlite3_column_int64(statement, column) }
}
