import QundaoCore
import SwiftUI

struct ContentView: View {
  @Environment(AppStore.self) var store
  var body: some View {
    VStack(spacing: 0) {
      MainTitlebar()
      HStack(spacing: 0) {
        MainSidebar()
        VStack(spacing: 0) {
          if let error = store.error { errorBanner(error) }
          PageHost(page: store.page).frame(maxWidth: .infinity, maxHeight: .infinity)
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
      }
      StatusFooter()
    }
    .frame(minWidth: 940, minHeight: 620)
    .background(P5.mainPaper).foregroundStyle(P5.ink).tint(P5.red)
    .buttonStyle(P5ButtonStyle()).preferredColorScheme(.light)
    .overlay(alignment: .topTrailing) { MainAttentionArrival().padding(.top, 48).padding(.trailing, 24) }
    .ignoresSafeArea(.container, edges: .top)
    .sheet(item: Bindable(store).detail) { AttentionDetail(item: $0).environment(store) }
  }
  private func errorBanner(_ error: String) -> some View {
    HStack(alignment: .center, spacing: 10) {
      Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
      Text(error).font(.caption).lineLimit(2).help(error)
      Spacer(minLength: 4)
      Button("查看日志") { store.page = .logs }.buttonStyle(.borderless).font(.caption)
      Button { store.error = nil } label: { Image(systemName: "xmark") }
        .buttonStyle(.plain).foregroundStyle(.secondary).accessibilityLabel("关闭提示")
    }.padding(.horizontal, 18).padding(.vertical, 10).background(.orange.opacity(0.06))
  }
}

/// 主窗口页面容器：每个页面首次访问时创建独立的 NSHostingView，之后只挂上 / 卸下，不重建。
/// SwiftUI 的 opacity(0) 会把隐藏页面的 AppKit 子视图摘下、显示时重新挂载，整棵表格和文字要重新排版；
/// 这里保留宿主和状态，仅将当前页面挂到窗口，隐藏页不参与排版。
private struct PageHost: NSViewRepresentable {
  let page: Page
  @Environment(AppStore.self) private var store
  func makeNSView(context: Context) -> PageContainerView { PageContainerView(store: store) }
  func updateNSView(_ view: PageContainerView, context: Context) { view.show(page) }
}

final class PageContainerView: NSView {
  private let store: AppStore
  private var hosts: [Page: NSView] = [:]
  private var current: Page?
  /// 让各页面知道自己是否可见：隐藏页面暂停实时任务，重新显示时刷新输入框。
  @MainActor @Observable final class Visibility { var active: Page? }
  private let visibility = Visibility()
  init(store: AppStore) { self.store = store; super.init(frame: .zero) }
  required init?(coder: NSCoder) { fatalError("不使用归档初始化") }
  @MainActor func show(_ page: Page) {
    guard page != current else { return }
    let first = current == nil
    makeHost(page)
    guard let host = hosts[page] else { return }
    if host.frame != bounds { host.frame = bounds }
    host.isHidden = false
    if host.superview !== self { addSubview(host) }
    // 隐藏页面从窗口卸下（对象与 SwiftUI 状态保留）：仍挂在窗口里的宿主会随日志刷新、状态变化
    // 参与每帧排版与渲染，真实触控板滚动时与当前页抢主线程。重新挂回不重建视图树。
    for (key, other) in hosts where key != page && other.superview != nil { other.removeFromSuperview() }
    current = page
    visibility.active = page
    if first { prewarm() } else { PerfProbe.pageSwitch(to: page.rawValue) }
  }
  /// 首屏显示后，空闲时逐个预建其余页面（每次一个，间隔让出主线程）：临时挂到最底层完成首次排版与渲染，再卸下。
  @MainActor private func prewarm() {
    Task { @MainActor [weak self] in
      try? await Task.sleep(nanoseconds: 1_500_000_000)
      for page in Page.allCases {
        guard let self else { return }
        guard self.hosts[page] == nil else { continue }
        self.makeHost(page)
        if let host = self.hosts[page] {
          host.alphaValue = 0
          host.frame = self.bounds
          self.addSubview(host, positioned: .below, relativeTo: nil)
          host.layoutSubtreeIfNeeded()
          host.displayIfNeeded()
          try? await Task.sleep(nanoseconds: 50_000_000)
          host.alphaValue = 1
          if self.current != page { host.removeFromSuperview() }
        }
        try? await Task.sleep(nanoseconds: 250_000_000)
      }
    }
  }
  override func layout() {
    super.layout()
    if let current, let host = hosts[current], host.frame != bounds { host.frame = bounds }
  }
  @MainActor private func makeHost(_ page: Page) {
    if hosts[page] == nil {
      let root = AnyView(PageRoot(page: page, visibility: visibility).environment(store).tint(P5.red)
        .foregroundStyle(P5.ink).buttonStyle(P5ButtonStyle()).environment(\.colorScheme, .light))
      let host: NSView
      switch page {
      case .rules, .appearance, .connection: host = SettingsScrollView(content: root)
      default:
        let hosting = NSHostingView(rootView: root)
        hosting.sizingOptions = []
        // 页面宿主位于详情栏内部，由外层 SwiftUI 处理工具栏安全区。
        hosting.safeAreaRegions = []
        host = hosting
      }
      // 不用约束：拖动窗口时只给可见页面设置尺寸，隐藏页面在显示前再调整，避免全部页面跟着重新排版。
      host.translatesAutoresizingMaskIntoConstraints = true
      host.autoresizingMask = []
      host.frame = bounds
      hosts[page] = host
    }
  }
}

private struct PageRoot: View {
  let page: Page
  let visibility: PageContainerView.Visibility
  var body: some View {
    let active = visibility.active == page
    content(active: active).environment(\.pageActive, active)
  }
  @ViewBuilder private func content(active: Bool) -> some View {
    switch page {
    case .attention: AttentionPage()
    case .summary: SummaryPage()
    case .groups: GroupsPage()
    case .logs: LogsPage(active: active)
    default:
      // 偏好设置页由 PageContainerView 放进 AppKit 滚动视图（SettingsScrollView），这里只给内容。
      VStack(alignment: .leading, spacing: 0) {
        PageHeading(title: page.rawValue, subtitle: settingsSubtitle)
        VStack(alignment: .leading, spacing: 22) {
          switch page {
          case .rules: RulesPage()
          case .appearance: AppearancePage()
          case .connection: ConnectionPage()
          default: EmptyView()
          }
        }.padding(24).frame(maxWidth: 1100, alignment: .leading)
          .frame(maxWidth: .infinity, alignment: .topLeading)
      }.background(P5.mainPaper)
    }
  }
  private var settingsSubtitle: String {
    switch page {
    case .rules: return "让与你有关的消息，准确地找到你。"
    case .appearance: return "把关注留在眼前，让提醒恰到好处。"
    default: return "连接消息来源，选择适合你的模型。"
    }
  }
}

private struct PageActiveKey: EnvironmentKey { static let defaultValue = true }
extension EnvironmentValues {
  /// 页面是否为当前可见页；保留的隐藏页面据此暂停实时任务或在重新显示时刷新。
  var pageActive: Bool {
    get { self[PageActiveKey.self] }
    set { self[PageActiveKey.self] = newValue }
  }
}

struct AttentionCard: View {
  @Environment(AppStore.self) var store
  let item: Attention
  var compact = false
  var body: some View {
    P5PaperCard {
      HStack {
        Label(item.groupName, systemImage: "person.2.fill").font(.caption).lineLimit(1)
        Spacer()
        Text(item.message.date, style: .time).font(.caption2).foregroundStyle(.secondary)
      }
      if !compact {
        HStack {
          Text(item.title).font(.headline)
          Spacer()
          Text(item.definite ? "直接命中" : "AI 判断").font(.caption2).foregroundStyle(P5.red)
        }
      }
      Text("\(item.message.sender)：\(item.message.text)").font(compact ? .caption : .callout)
        .lineLimit(compact ? 3 : 5).textSelection(.enabled)
      Text(item.reason).font(.caption2).foregroundStyle(.secondary).lineLimit(compact ? 2 : nil)
      HStack {
        Button("查看原文") { store.detail = item }
        if item.status == "pending" {
          Button("已处理") { store.resolve(item) }
          Button("稍后 15 分钟") { store.snooze(item) }
        } else {
          Text(item.status == "done" ? "已处理" : "稍后提醒").foregroundStyle(.secondary)
        }
      }.buttonStyle(P5ButtonStyle()).controlSize(.small)
    }
  }
}
struct AttentionDetail: View {
  @Environment(AppStore.self) var store
  @Environment(\.dismiss) var dismiss
  let item: Attention
  var body: some View {
    VStack(alignment: .leading, spacing: 20) {
      HStack {
        Text(item.groupName).font(.title2.bold())
        Spacer()
        Button("关闭") { dismiss() }
      }
      let context = store.cachedMessages.filter {
        $0.accountID == item.message.accountID && $0.groupID == item.message.groupID
          && abs($0.timestamp - item.message.timestamp) < 300000
      }
      let messages = context.contains(where: { $0.key == item.message.key }) ? context : context + [item.message]
      ChatTranscript(messages: messages.sorted { $0.timestamp < $1.timestamp },
                     selfID: store.activeAccount?.subjectID ?? "", highlightedID: item.message.id)
      Text(item.reason).font(.caption).foregroundStyle(.secondary)
      HStack {
        Button("标记已处理") {
          store.resolve(item)
          dismiss()
        }.buttonStyle(P5ButtonStyle(kind: .primary))
        Button("稍后提醒") {
          store.snooze(item)
          dismiss()
        }
        Button("复制原文") {
          NSPasteboard.general.clearContents()
          NSPasteboard.general.setString(item.message.text, forType: .string)
        }
      }
    }.padding(24).frame(width: 620, height: 550).background(P5.mainPaper)
      .tint(P5.red).foregroundStyle(P5.ink).preferredColorScheme(.light)
  }
}

/// 偏好设置页的滚动容器：AppKit 滚动视图 + 按内容高度定尺寸的 SwiftUI 文档视图。
/// SwiftUI ScrollView 每滚动一帧都会通知视图图更新，整页重新排版、测量文字，惯性滚动时掉帧；
/// 这里滚动只移动 clip view，文档视图尺寸不变，SwiftUI 不参与。宽度变化时内容重排并回报新高度。
final class SettingsScrollView: NSScrollView {
  private final class HeightSink { weak var target: SettingsScrollView? }
  private let document: NSHostingView<AnyView>
  private var contentHeight: CGFloat = 0
  init(content: AnyView) {
    let sink = HeightSink()
    let measured = AnyView(
      content
        .fixedSize(horizontal: false, vertical: true)
        .background(GeometryReader { proxy in
          Color.clear
            .onAppear { sink.target?.contentMeasured(proxy.size.height) }
            .onChange(of: proxy.size.height) { _, height in sink.target?.contentMeasured(height) }
        })
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading))
    document = NSHostingView(rootView: measured)
    document.sizingOptions = []
    // 关键：滚动时 AppKit 每帧移动文档视图原点，NSHostingView 默认把它当作安全区变化，
    // 触发整个视图图更新（含隐藏页面的弹出菜单、侧边栏列表与辅助功能文字解析），真实触控板滚动严重掉帧。
    // 文档视图在滚动视图内部，不需要安全区。
    document.safeAreaRegions = []
    document.translatesAutoresizingMaskIntoConstraints = true
    super.init(frame: .zero)
    sink.target = self
    drawsBackground = false
    borderType = .noBorder
    hasVerticalScroller = true
    autohidesScrollers = true
    contentView.drawsBackground = false
    documentView = document
  }
  required init?(coder: NSCoder) { fatalError("不使用归档初始化") }
  private func contentMeasured(_ height: CGFloat) {
    guard height > 1, abs(height - contentHeight) > 0.5 else { return }
    contentHeight = height
    needsLayout = true
  }
  override func layout() {
    super.layout()
    let size = contentView.bounds.size
    let frame = NSRect(x: 0, y: 0, width: size.width, height: max(contentHeight, size.height))
    if document.frame != frame { document.frame = frame }
  }
}
