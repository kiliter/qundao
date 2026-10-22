import AppKit
import SwiftUI

struct MainTitlebar: View {
  @Environment(AppStore.self) private var store
  var body: some View {
    HStack(spacing: 12) {
      Text("群岛 / 工作空间").font(.system(size: 10, weight: .bold)).tracking(3)
        .foregroundStyle(.white.opacity(0.75))
      Spacer()
      if store.syncing || store.analyzing { ProgressView().controlSize(.mini).tint(.white) }
      Button(store.running ? "暂停监听" : "开始监听", systemImage: store.running ? "pause.fill" : "play.fill") {
        store.running ? store.stop() : store.start()
      }.buttonStyle(.plain).font(.system(size: 11, weight: .semibold)).foregroundStyle(.white)
        .keyboardShortcut("l", modifiers: [.command, .shift])
        .help("开始或暂停监听（⇧⌘L）")
    }.padding(.leading, 86).padding(.trailing, 20).frame(height: 38)
      .background(P5.ink).background(WindowDragRegion())
      .overlay(alignment: .bottom) { Rectangle().fill(.white.opacity(0.17)).frame(height: 1) }
  }
}

/// macOS 14 的自定义标题栏拖动区，仅覆盖标题背景，不抢占按钮事件。
private struct WindowDragRegion: NSViewRepresentable {
  func makeNSView(context: Context) -> DragView { DragView() }
  func updateNSView(_ nsView: DragView, context: Context) {}
  final class DragView: NSView {
    override var mouseDownCanMoveWindow: Bool { true }
    override func mouseDown(with event: NSEvent) { window?.performDrag(with: event) }
  }
}

struct MainSidebar: View {
  @Environment(AppStore.self) private var store
  var body: some View {
    GeometryReader { proxy in
      let compact = proxy.size.height < 620
      VStack(alignment: .leading, spacing: 0) {
        HStack(spacing: 12) {
          P5Spark().fill(P5.red).frame(width: 30, height: 34).rotationEffect(.degrees(-12))
          VStack(alignment: .leading, spacing: 7) {
            Text("群岛").font(P5.heavy(28)).tracking(4).foregroundStyle(.white)
            Text("只关注，与你有关。").font(.system(size: 9)).tracking(2).foregroundStyle(.white.opacity(0.55))
          }
        }.padding(.horizontal, 22).padding(.top, compact ? 18 : 30).padding(.bottom, compact ? 16 : 26)
        ScrollView {
          VStack(alignment: .leading, spacing: compact ? 4 : 7) {
            sectionTitle("工作空间")
            ForEach([Page.attention, .summary, .groups]) { nav($0, compact: compact) }
            sectionTitle("偏好设置").padding(.top, compact ? 14 : 22)
            ForEach([Page.rules, .appearance, .connection, .logs]) { nav($0, compact: compact) }
          }.padding(.horizontal, 10).padding(.bottom, 16)
        }.scrollIndicators(.hidden)
        SidebarStatus()
      }
    }.frame(width: 200).background(P5.ink).environment(\.colorScheme, .dark)
      .overlay(alignment: .trailing) { Rectangle().fill(P5.red).frame(width: 5) }
  }
  private func sectionTitle(_ title: String) -> some View {
    Text(title).font(.system(size: 9, weight: .medium)).tracking(3)
      .foregroundStyle(.white.opacity(0.45)).padding(.leading, 14).padding(.bottom, 4)
  }
  private func nav(_ page: Page, compact: Bool) -> some View {
    let selected = store.page == page
    return Button { store.page = page } label: {
      HStack(spacing: 12) {
        Image(systemName: page.icon).font(.system(size: 16, weight: .medium)).frame(width: 20)
        Text(page.rawValue).font(.system(size: 12, weight: selected ? .heavy : .medium))
        Spacer(minLength: 2)
        if page == .attention && store.pendingFocusCount > 0 {
          Text(verbatim: "\(store.pendingFocusCount)").font(P5.numeral(13)).foregroundStyle(P5.red)
        }
      }.padding(.horizontal, 14).frame(height: compact ? 36 : 42)
        .foregroundStyle(selected ? P5.ink : .white.opacity(0.68))
        .background {
          if selected {
            P5Slant(slant: 0.035).fill(P5.red).offset(x: 3, y: 4)
            P5Slant(slant: 0.035).fill(.white)
          }
        }
        .rotationEffect(.degrees(selected ? -1.5 : 0))
        .contentShape(Rectangle())
    }.buttonStyle(.plain)
      .keyboardShortcut(KeyEquivalent(Character(String((Page.allCases.firstIndex(of: page) ?? 0) + 1))), modifiers: .command)
      .accessibilityAddTraits(selected ? .isSelected : [])
      .accessibilityIdentifier("main-nav-\(page.id)")
  }
}

private struct SidebarStatus: View {
  @Environment(AppStore.self) private var store
  var body: some View {
    VStack(alignment: .leading, spacing: 9) {
      Rectangle().fill(.white.opacity(0.15)).frame(height: 1).padding(.bottom, 7)
      HStack(spacing: 8) {
        Circle().fill(store.running ? Color(red: 0.65, green: 0.86, blue: 0.72) : P5.grey).frame(width: 5, height: 5)
        Text(store.running ? "监听中" : "监听已暂停").font(.system(size: 11, weight: .medium))
      }.foregroundStyle(.white.opacity(0.85))
      Text("白名单 \(store.preferences.selectedGroups.count) 个群")
        .font(.system(size: 10)).foregroundStyle(.white.opacity(0.45))
    }.padding(20)
  }
}

struct StatusFooter: View {
  @Environment(AppStore.self) private var store
  var body: some View {
    HStack(spacing: 8) {
      Image(systemName: "checkmark.shield").font(.system(size: 10))
      Text(store.streamStatus).lineLimit(1).help(store.streamStatus)
      if store.running { Text("· " + store.decisionStatus).lineLimit(1).help(store.decisionStatus) }
      Spacer(minLength: 16)
      Text("已阅仅在群岛生效").fixedSize()
      if let time = store.lastSync {
        Text("同步于 \(time.formatted(date: .omitted, time: .shortened))").fixedSize()
      }
    }.font(.system(size: 10)).foregroundStyle(P5.secondary)
      .padding(.horizontal, 16).frame(height: 30).background(P5.mainPaper)
      .overlay(alignment: .top) { Rectangle().fill(P5.ink.opacity(0.15)).frame(height: 1) }
  }
}

/// 复用既有的新关注阶段，不增加消息监听或额外定时器。
struct MainAttentionArrival: View {
  @Environment(AppStore.self) private var store
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  var body: some View {
    let visible = store.activity.phase == .attention && !store.isQuiet && !reduceMotion
    ZStack {
      if visible {
        Label("新的关注！", systemImage: "sparkle")
          .font(P5.heavy(20)).foregroundStyle(.white)
          .padding(.horizontal, 24).padding(.vertical, 13)
          .background(P5.red, in: P5Slant(slant: 0.07))
          .shadow(color: P5.ink, radius: 0, x: 4, y: 4)
          .rotationEffect(.degrees(-4))
          .transition(.move(edge: .trailing).combined(with: .opacity))
      }
    }.animation(reduceMotion ? nil : P5.snap, value: visible)
      .allowsHitTesting(false).accessibilityHidden(true)
  }
}
