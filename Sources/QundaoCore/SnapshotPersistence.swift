import Foundation

/// 应用状态持久化：~/Library/Application Support/Qundao/qundao.sqlite。
///
/// - 群、消息缓存、关注记录、摘要（含原文证据）、Jev 待判断批次按记录一行存储；
///   其余字段（偏好、摘要标记与待办、实时缓冲、去重集合等）各存一行 meta。
/// - save 在一个事务中只写入内容变化的行，并删除已不存在的记录；
///   摘要结果、原文证据与成功标记因此仍是原子提交，失败时磁盘保持上一次状态。
/// - 首次使用时从旧版 state.json 一次性导入，成功后将其改名为 state.json.migrated 备份，不删除。
public final class SnapshotPersistence {
  public let directory: URL
  public static let databaseName = "qundao.sqlite"
  private static let collectionKinds = ["groups", "messages", "attentions", "digests", "decisionBatches"]
  private var database: SQLiteDatabase?
  /// 已提交到磁盘的内容，作为增量基准。nil 表示尚未与磁盘同步。
  private var committed: Committed?
  /// 每类记录上次参与比较的数组，用于整体相等时跳过逐行比较。
  private var lastItems: [String: Any] = [:]
  private var stagedItems: [String: Any] = [:]
  private struct Row { var seq: Int64; var value: Any }
  private struct Committed {
    var meta: [String: Data] = [:]
    var rows: [String: [String: Row]] = [:]
    var order: [String: [String]] = [:]
  }
  private struct Pending {
    var metaWrites: [(String, Data)] = [], metaDeletes: [String] = []
    var rowWrites: [(kind: String, key: String, seq: Int64, index: (SQLiteDatabase.Value, SQLiteDatabase.Value, SQLiteDatabase.Value), payload: Data)] = []
    var rowDeletes: [(String, String)] = []
    var isEmpty: Bool { metaWrites.isEmpty && metaDeletes.isEmpty && rowWrites.isEmpty && rowDeletes.isEmpty }
  }
  private static let encoder: JSONEncoder = { let e = JSONEncoder(); e.outputFormatting = .sortedKeys; return e }()

  public init(directory: URL) { self.directory = directory }
  var databaseURL: URL { directory.appendingPathComponent(Self.databaseName) }
  var legacyURL: URL { directory.appendingPathComponent("state.json") }

  public func load() throws -> AppSnapshot {
    let db = try open()
    var stored = try readStored(db)
    if stored.meta.isEmpty && stored.payloads.isEmpty, FileManager.default.fileExists(atPath: legacyURL.path) {
      // 旧数据：完整解码后在单个事务中导入，再改名备份。导入失败不改动旧文件。
      let legacy = try JSONDecoder().decode(AppSnapshot.self, from: Data(contentsOf: legacyURL))
      committed = Committed()
      try write(legacy, migrated: true)
      stored = try readStored(db)
    }
    if stored.meta["migratedFromJSON"] != nil, FileManager.default.fileExists(atPath: legacyURL.path) { backupLegacy() }
    // 以默认快照为底，缺失字段使用默认值，旧版 Codable 兼容逻辑保持不变。
    var root = try JSONSerialization.jsonObject(with: JSONEncoder().encode(AppSnapshot())) as? [String: Any] ?? [:]
    for (key, data) in stored.meta where !key.hasPrefix("_") && key != "migratedFromJSON" {
      root[key] = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
    }
    for kind in Self.collectionKinds {
      let order = stored.order[kind] ?? []
      if order.isEmpty && kind == "decisionBatches" {
        if stored.meta["_decisionBatchesPresent"] != nil { root[kind] = [Any]() }
        continue
      }
      root[kind] = try order.map { try JSONSerialization.jsonObject(with: stored.payloads[kind]![$0]!.payload) }
    }
    let snapshot = try JSONDecoder().decode(AppSnapshot.self, from: JSONSerialization.data(withJSONObject: root))
    // 用解码后的记录作为比较基准，后续保存只需结构比较。
    var base = Committed(meta: stored.meta)
    func remember<T>(_ kind: String, _ items: [T], key: (T) -> String) {
      var rows: [String: Row] = [:]
      for item in items { let k = key(item); rows[k] = Row(seq: stored.payloads[kind]?[k]?.seq ?? 0, value: item) }
      base.rows[kind] = rows; base.order[kind] = items.map(key)
    }
    remember("groups", snapshot.groups) { $0.id }
    remember("messages", snapshot.messages) { $0.key }
    remember("attentions", snapshot.attentions) { $0.id }
    remember("digests", snapshot.digests) { $0.id.uuidString }
    remember("decisionBatches", snapshot.decisionBatches ?? []) { $0.id.uuidString }
    committed = base
    lastItems = ["groups": snapshot.groups, "messages": snapshot.messages, "attentions": snapshot.attentions,
                 "digests": snapshot.digests, "decisionBatches": snapshot.decisionBatches ?? []]
    return snapshot
  }

  public func save(_ snapshot: AppSnapshot) throws {
    if committed == nil { _ = try load() }
    try write(snapshot, migrated: false)
  }

  // MARK: 内部

  private func open() throws -> SQLiteDatabase {
    if let database { return database }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                            attributes: [.posixPermissions: 0o700])
    let path = databaseURL.path
    if !FileManager.default.fileExists(atPath: path) {
      FileManager.default.createFile(atPath: path, contents: nil, attributes: [.posixPermissions: 0o600])
    }
    let db = try SQLiteDatabase(path: path)
    try db.execute("""
      PRAGMA journal_mode = WAL;
      PRAGMA synchronous = FULL;
      CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value BLOB NOT NULL);
      CREATE TABLE IF NOT EXISTS records (
        kind TEXT NOT NULL, key TEXT NOT NULL, seq INTEGER NOT NULL,
        account_id TEXT, group_id TEXT, ts INTEGER, payload BLOB NOT NULL,
        PRIMARY KEY (kind, key));
      CREATE INDEX IF NOT EXISTS records_order ON records(kind, seq);
      CREATE INDEX IF NOT EXISTS records_scope ON records(kind, account_id, group_id, ts);
      """)
    // WAL 附属文件同样只允许本人读写。
    for suffix in ["-wal", "-shm"] {
      try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path + suffix)
    }
    database = db
    return db
  }

  private struct Stored {
    var meta: [String: Data] = [:]
    var payloads: [String: [String: (seq: Int64, payload: Data)]] = [:]
    var order: [String: [String]] = [:]
  }
  private func readStored(_ db: SQLiteDatabase) throws -> Stored {
    var stored = Stored()
    try db.run("SELECT key, value FROM meta") { row in
      stored.meta[SQLiteDatabase.text(row, 0)] = SQLiteDatabase.blob(row, 1)
    }
    try db.run("SELECT kind, key, seq, payload FROM records ORDER BY kind, seq") { row in
      let kind = SQLiteDatabase.text(row, 0), key = SQLiteDatabase.text(row, 1)
      stored.payloads[kind, default: [:]][key] = (SQLiteDatabase.int(row, 2), SQLiteDatabase.blob(row, 3))
      stored.order[kind, default: []].append(key)
    }
    return stored
  }

  private func write(_ snapshot: AppSnapshot, migrated: Bool) throws {
    let db = try open()
    var next = committed ?? Committed()
    var pending = Pending()
    try diffMeta(snapshot, migrated: migrated, into: &next, &pending)
    try diff("groups", snapshot.groups, key: { $0.id }, index: { _ in (.null, .null, .null) }, into: &next, &pending)
    try diff("messages", snapshot.messages, key: { $0.key },
             index: { (.text($0.accountID), .text($0.groupID), .int($0.timestamp)) }, into: &next, &pending)
    try diff("attentions", snapshot.attentions, key: { $0.id },
             index: { (.text($0.message.accountID), .text($0.message.groupID), .int($0.message.timestamp)) }, into: &next, &pending)
    try diff("digests", snapshot.digests, key: { $0.id.uuidString },
             index: { (.text($0.accountID), .text($0.groupID), .int(Int64($0.messageDate.timeIntervalSince1970 * 1000))) },
             into: &next, &pending)
    try diff("decisionBatches", snapshot.decisionBatches ?? [], key: { $0.id.uuidString },
             index: { (.text($0.scope.account), .text($0.scope.group), .null) }, into: &next, &pending)
    defer { stagedItems = [:] }
    guard !pending.isEmpty else { commit(next); return }
    try db.transaction {
      for (key, data) in pending.metaWrites {
        try db.run("INSERT INTO meta(key, value) VALUES(?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value",
                   [.text(key), .blob(data)])
      }
      for key in pending.metaDeletes { try db.run("DELETE FROM meta WHERE key = ?", [.text(key)]) }
      for (kind, key) in pending.rowDeletes {
        try db.run("DELETE FROM records WHERE kind = ? AND key = ?", [.text(kind), .text(key)])
      }
      for row in pending.rowWrites {
        try db.run("""
          INSERT INTO records(kind, key, seq, account_id, group_id, ts, payload) VALUES(?, ?, ?, ?, ?, ?, ?)
          ON CONFLICT(kind, key) DO UPDATE SET seq = excluded.seq, account_id = excluded.account_id,
            group_id = excluded.group_id, ts = excluded.ts, payload = excluded.payload
          """, [.text(row.kind), .text(row.key), .int(row.seq), row.index.0, row.index.1, row.index.2, .blob(row.payload)])
      }
    }
    // 只有提交成功才更新增量基准；失败时下一次保存会重新写入全部差异。
    commit(next)
  }

  /// meta 字段按值缓存：与上次编码时相等则直接复用字节，不再排序和 JSON 编码。
  /// 补查期间每页都会保存，绝大多数字段未变，这里是保存的主要耗时。
  private var metaCache: [String: (value: Any, data: Data)] = [:]
  private func cached<T: Encodable & Equatable>(_ key: String, _ value: T, encode: (T) throws -> Data) rethrows -> Data {
    if let hit = metaCache[key], let old = hit.value as? T, old == value { return hit.data }
    let data = try encode(value)
    metaCache[key] = (value, data)
    return data
  }
  private func commit(_ next: Committed) {
    committed = next
    lastItems.merge(stagedItems) { $1 }
  }
  private func diffMeta(_ s: AppSnapshot, migrated: Bool, into next: inout Committed, _ pending: inout Pending) throws {
    func enc<T: Encodable>(_ value: T) throws -> Data { try Self.encoder.encode(value) }
    // 集合排序后保存，内容相同则字节相同，避免无意义写入。
    var desired: [String: Data] = [
      "preferences": try cached("preferences", s.preferences, encode: enc),
      "checkpoints": try cached("checkpoints", s.checkpoints, encode: enc),
      "analyzed": try cached("analyzed", s.analyzed) { try enc($0.sorted()) },
      "seen": try cached("seen", s.seen) { try enc($0.sorted()) },
      "pendingAI": try cached("pendingAI", s.pendingAI) { try enc($0.sorted()) },
    ]
    if let v = s.pendingJev { desired["pendingJev"] = try cached("pendingJev", v) { try enc($0.sorted()) } }
    if let v = s.pendingPeriodic { desired["pendingPeriodic"] = try cached("pendingPeriodic", v) { try enc($0.sorted()) } }
    if let v = s.summaryState { desired["summaryState"] = try cached("summaryState", v, encode: enc) }
    if let v = s.realtimeBuffer { desired["realtimeBuffer"] = try cached("realtimeBuffer", v, encode: enc) }
    if let v = s.alphaRESTVersion { desired["alphaRESTVersion"] = try enc(v) }
    if s.decisionBatches != nil { desired["_decisionBatchesPresent"] = Data("true".utf8) }
    if migrated { desired["migratedFromJSON"] = try enc(Date().timeIntervalSince1970) }
    else if let flag = next.meta["migratedFromJSON"] { desired["migratedFromJSON"] = flag }
    for (key, data) in desired where next.meta[key] != data { pending.metaWrites.append((key, data)) }
    for key in next.meta.keys where desired[key] == nil { pending.metaDeletes.append(key) }
    next.meta = desired
  }

  /// 结构比较找出变化的记录，只编码变化的行；已有记录相对顺序不变时沿用原序号。
  private func diff<T: Encodable & Equatable>(
    _ kind: String, _ items: [T], key keyOf: (T) -> String,
    index: (T) -> (SQLiteDatabase.Value, SQLiteDatabase.Value, SQLiteDatabase.Value),
    into next: inout Committed, _ pending: inout Pending
  ) throws {
    // 与上次提交的数组相同（常见于只改了 meta 的保存）时无需逐条比较。
    // lastItems 只在事务提交成功后更新，因此相等时磁盘内容与 committed 一致。
    if let last = lastItems[kind] as? [T], last == items { return }
    stagedItems[kind] = items
    var latest: [String: T] = [:], keys: [String] = []
    for item in items {
      let key = keyOf(item)
      // 同主键重复时保留最后一条，与按主键覆盖语义一致。
      if latest.updateValue(item, forKey: key) != nil { keys.removeAll { $0 == key } }
      keys.append(key)
    }
    let old = next.rows[kind] ?? [:]
    let present = Set(keys)
    let kept = keys.filter { old[$0] != nil }
    let oldOrder = (next.order[kind] ?? []).filter { present.contains($0) }
    // 新记录只能追加在已有记录之后，否则整体重排序号。
    var sawNew = false, reorder = kept != oldOrder
    for key in keys where !reorder {
      if old[key] == nil { sawNew = true } else if sawNew { reorder = true }
    }
    var seq = reorder ? 0 : (old.values.map(\.seq).max() ?? 0)
    var rows: [String: Row] = [:]
    for key in keys {
      let item = latest[key]!
      let previous = old[key]
      let number: Int64
      if !reorder, let previous { number = previous.seq } else { seq += 1; number = seq }
      if previous?.seq != number || (previous?.value as? T) != item {
        pending.rowWrites.append((kind, key, number, index(item), try Self.encoder.encode(item)))
      }
      rows[key] = Row(seq: number, value: item)
    }
    for key in old.keys where rows[key] == nil { pending.rowDeletes.append((kind, key)) }
    next.rows[kind] = rows
    next.order[kind] = keys
  }

  private func backupLegacy() {
    var target = directory.appendingPathComponent("state.json.migrated")
    if FileManager.default.fileExists(atPath: target.path) {
      target = directory.appendingPathComponent("state.json.migrated-\(Int(Date().timeIntervalSince1970))")
    }
    try? FileManager.default.moveItem(at: legacyURL, to: target)
  }
}
