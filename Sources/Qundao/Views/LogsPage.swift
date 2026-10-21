import AppKit
import QundaoCore
import SwiftUI

@MainActor private final class LogBrowser: ObservableObject {
  @Published var category: DiagnosticCategory?
  @Published var pages: [DiagnosticPage] = []
  @Published var pageIndex = 0
  @Published var pageSize = 50
  @Published var following = true
  @Published var live = true
  @Published private(set) var latestRevision: UInt64 = 0
  @Published private(set) var lastRefresh: Date?
  @Published var loading = false
  @Published var error: String?
  @Published var selected: DiagnosticRecord?
  private var version = UUID()
  private let archive = EventLog.shared.diagnostics
  private var lastRevision: UInt64?
  var hasNewRecords: Bool { lastRevision != archive.revision }
  var rows: [DiagnosticRecord] { pages.indices.contains(pageIndex) ? pages[pageIndex].records : [] }
  var canNext: Bool { pages.indices.contains(pageIndex) && pages[pageIndex].next != nil }
  func observeUpdates() async {
    // 先订阅再读取，保证页面打开期间产生的日志也会被接收。
    let updates = archive.updates()
    await first()
    for await revision in updates {
      guard !Task.isCancelled else { break }
      latestRevision = revision
      // 手动翻页或筛选正在读盘时，等待它结束再决定更新，不能吞掉这一版通知。
      while loading && !Task.isCancelled {
        try? await Task.sleep(nanoseconds: 50_000_000)
      }
      guard !Task.isCancelled else { break }
      if live && pageIndex == 0 && hasNewRecords { await first() }
    }
  }
  func first(follow: Bool? = nil) async {
    if let follow { following = follow }
    version = UUID()
    let current = version, category = category, size = pageSize, archive = archive, revision = archive.revision
    loading = true
    do {
      let page = try await Task.detached { try archive.page(category: category, limit: size) }.value
      guard version == current else { return }
      pages = [page]; pageIndex = 0; error = nil
      lastRevision = revision
      lastRefresh = Date()
      if following || selected == nil { selected = page.records.first }
    } catch { if version == current { self.error = error.localizedDescription } }
    if version == current { loading = false }
  }
  func next() async {
    guard !loading, canNext, let cursor = pages[pageIndex].next else { return }
    following = false
    if pages.indices.contains(pageIndex + 1) { pageIndex += 1; selected = rows.first; return }
    let current = version, category = category, size = pageSize, archive = archive
    loading = true
    do {
      let page = try await Task.detached { try archive.page(before: cursor, category: category, limit: size) }.value
      guard current == version else { return }
      pages.append(page); pageIndex += 1; selected = rows.first; error = nil
    } catch { if current == version { self.error = error.localizedDescription } }
    if version == current { loading = false }
  }
  func previous() {
    guard pageIndex > 0 else { return }
    following = false; pageIndex -= 1; selected = rows.first
  }
  func choose(_ id: UUID?) {
    following = false
    selected = rows.first { $0.id == id }
  }
}

struct LogsPage: View {
  @StateObject private var browser = LogBrowser()
  var body: some View {
    VStack(spacing: 0) {
      HStack(spacing: 12) {
        Picker("日志来源", selection: $browser.category) {
          Text("全部来源").tag(Optional<DiagnosticCategory>.none)
          ForEach(DiagnosticCategory.allCases, id: \.self) { Text($0.rawValue).tag(Optional($0)) }
        }.frame(width: 180)
        Toggle("实时刷新", isOn: $browser.live).toggleStyle(.checkbox)
          .help("新日志写入后立即刷新最新页；查看历史分页时提示有新日志")
        Toggle("跟随最新", isOn: Binding(get: { browser.following }, set: { enabled in
          browser.following = enabled
          if enabled { Task { await browser.first(follow: true) } }
        })).toggleStyle(.checkbox)
        if browser.loading { ProgressView().controlSize(.small) }
        Spacer()
        Button("刷新") { Task { await browser.first() } }.disabled(browser.loading)
        Button("打开归档", systemImage: "folder") {
          NSWorkspace.shared.open(EventLog.shared.directory)
        }
      }.controlSize(.small).padding(16)
      HStack(spacing: 6) {
        Image(systemName: "doc.text.magnifyingglass")
        Text("入参和出参包含聊天原文；鉴权密钥已隐藏。按日留档，单文件 10 MB 后继续归档。")
        Spacer()
      }.font(.caption).foregroundStyle(.secondary).padding(.horizontal, 16).padding(.bottom, 12)
      if let error = browser.error {
        Text("读取日志失败：\(error)").font(.caption).foregroundStyle(.red).padding(8)
      }
      Divider()
      HSplitView {
        logList.frame(minWidth: 245, idealWidth: 300, maxWidth: 380)
        Group {
          if let item = browser.selected { LogDetail(record: item) }
          else { ContentUnavailableView("选择一条日志", systemImage: "doc.text",
            description: Text("开始监听或测试连接后，入参和出参会在这里显示。")) }
        }.frame(minWidth: 360, maxWidth: .infinity, maxHeight: .infinity)
      }
      Divider()
      HStack(spacing: 12) {
        VStack(alignment: .leading, spacing: 3) {
          Text(browser.live ? (browser.following ? "● 实时刷新并跟随最新" : "● 实时刷新 · 保持当前详情") : "实时刷新已暂停")
            .foregroundStyle(browser.live ? .green : .secondary)
          if let time = browser.lastRefresh {
            Text("更新于 \(time.formatted(date: .omitted, time: .standard))").foregroundStyle(.secondary)
          }
        }
        if browser.hasNewRecords {
          Button("有新日志") { Task { await browser.first(follow: true) } }
            .disabled(browser.loading)
        }
        Spacer()
        Picker("每页", selection: $browser.pageSize) {
          Text("25 条 / 页").tag(25); Text("50 条 / 页").tag(50); Text("100 条 / 页").tag(100)
        }.labelsHidden().frame(width: 105)
        Button("上一页") { browser.previous() }.disabled(browser.pageIndex == 0 || browser.loading)
        Text("第 \(browser.pageIndex + 1) 页 · \(browser.rows.count) 条").monospacedDigit()
        Button("下一页") { Task { await browser.next() } }.disabled(!browser.canNext || browser.loading)
        Button("回到最新") { Task { await browser.first(follow: true) } }.disabled(browser.loading)
      }.font(.caption).controlSize(.small).padding(14)
    }
    .task { await browser.observeUpdates() }
    .onChange(of: browser.live) { _, enabled in
      if enabled && browser.pageIndex == 0 { Task { await browser.first() } }
    }
    .onChange(of: browser.category) { _, _ in Task { await browser.first(follow: true) } }
    .onChange(of: browser.pageSize) { _, _ in Task { await browser.first(follow: true) } }
  }
  private var logList: some View {
    ScrollViewReader { proxy in
      List(selection: Binding(get: { browser.selected?.id }, set: { browser.choose($0) })) {
        ForEach(browser.rows) { item in
          VStack(alignment: .leading, spacing: 6) {
            HStack {
              Text(item.category.rawValue).font(.caption.weight(.medium))
              Spacer()
              Text(item.date, format: .dateTime.hour().minute().second()).font(.caption2).monospacedDigit()
            }.foregroundStyle(.secondary)
            Label(item.event, systemImage: item.error.isEmpty ? "doc.text" : "exclamationmark.circle")
              .font(.system(size: 12, weight: .medium)).foregroundStyle(item.error.isEmpty ? Color.primary : .orange)
              .lineLimit(1)
            HStack(spacing: 8) {
              if let status = item.statusCode { Text("HTTP \(status)") }
              if let duration = item.durationMS { Text("\(duration) ms") }
              Text(String(item.correlationID.prefix(8))).foregroundStyle(.tertiary)
            }.font(.system(size: 10, design: .monospaced))
          }.padding(.vertical, 6).tag(item.id).id(item.id)
        }
      }.listStyle(.inset).scrollContentBackground(.hidden)
        .overlay { if browser.rows.isEmpty && !browser.loading {
          ContentUnavailableView("暂无日志", systemImage: "doc.text",
            description: Text("该来源尚未产生记录。"))
        } }
        .onChange(of: browser.rows.first?.id) { _, id in
          if browser.following, let id { proxy.scrollTo(id, anchor: .top) }
        }
        .onChange(of: browser.following) { _, enabled in
          if enabled, let id = browser.rows.first?.id { proxy.scrollTo(id, anchor: .top) }
        }
        .onChange(of: browser.pageIndex) { _, _ in
          if let id = browser.rows.first?.id { proxy.scrollTo(id, anchor: .top) }
        }
        // 鼠标滚轮向历史方向浏览时立即停止跟随，避免新日志将阅读位置拉回。
        .background(LogScrollObserver { browser.following = false })
    }
  }
}

private struct LogDetail: View {
  let record: DiagnosticRecord
  @State private var tab = 0
  @State private var copied = false
  @State private var readable = true
  @State private var wrap = true
  private var content: String {
    let raw: String
    switch tab {
    case 0: raw = record.input.isEmpty ? "本条记录没有入参。" : record.input
    case 1: raw = record.output.isEmpty ? "本条记录没有出参，请通过关联编号查看对应完成或失败记录。" : record.output
    default: raw = record.error.isEmpty ? "无错误。" : record.error
    }
    return readable ? DiagnosticRecord.readableText(raw) : raw
  }
  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      VStack(alignment: .leading, spacing: 8) {
        HStack {
          Text(record.event).font(.headline)
          Spacer()
          Text(record.category.rawValue).font(.caption).foregroundStyle(.secondary)
        }
        Text(record.date.formatted(date: .numeric, time: .standard)).font(.caption).foregroundStyle(.secondary)
        Text("关联编号：\(record.correlationID)").font(.caption.monospaced()).textSelection(.enabled)
        if !record.scope.isEmpty { Text(record.scope).font(.caption).textSelection(.enabled).lineLimit(2).help(record.scope) }
        HStack {
          Picker("详情视角", selection: $tab) {
            Text("入参").tag(0); Text("出参").tag(1); Text("错误").tag(2)
          }.pickerStyle(.segmented).labelsHidden()
          Button(copied ? "已复制" : "复制内容") {
            NSPasteboard.general.clearContents(); NSPasteboard.general.setString(content, forType: .string)
            copied = true
          }.controlSize(.small)
        }
        HStack(spacing: 16) {
          Toggle("展开内嵌 JSON", isOn: $readable)
          Toggle("自动换行", isOn: $wrap)
        }.toggleStyle(.checkbox).font(.caption)
      }.padding(16)
      Divider()
      ScrollView(wrap ? .vertical : [.horizontal, .vertical]) {
        Text(content).font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
          .fixedSize(horizontal: !wrap, vertical: true)
          .frame(maxWidth: .infinity, alignment: .topLeading).padding(16)
      }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(.primary.opacity(0.025))
    }.onChange(of: tab) { _, _ in copied = false }
      .onChange(of: readable) { _, _ in copied = false }
      .onChange(of: record.id) { _, _ in copied = false }
  }
}

/// 仅观察日志列表范围的滚轮，不拦截系统滚动事件。
private struct LogScrollObserver: NSViewRepresentable {
  var onScroll: () -> Void
  func makeNSView(context: Context) -> ObserverView { ObserverView(onScroll: onScroll) }
  func updateNSView(_ view: ObserverView, context: Context) { view.onScroll = onScroll }
  final class ObserverView: NSView {
    var onScroll: () -> Void
    private var monitor: Any?
    init(onScroll: @escaping () -> Void) { self.onScroll = onScroll; super.init(frame: .zero) }
    required init?(coder: NSCoder) { fatalError("不使用归档初始化") }
    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
      guard window != nil else { return }
      monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
        if let self, event.window === self.window,
           self.bounds.contains(self.convert(event.locationInWindow, from: nil)), event.scrollingDeltaY != 0 {
          self.onScroll()
        }
        return event
      }
    }
    deinit { if let monitor { NSEvent.removeMonitor(monitor) } }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
  }
}
