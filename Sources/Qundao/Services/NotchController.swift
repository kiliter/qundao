import AppKit
import QuartzCore
import QundaoCore
import SwiftUI

@MainActor final class NotchController: ObservableObject {
  static var shared: NotchController?
  @Published var expanded = false
  @Published var pinned = false
  @Published var contentVisible = false
  private let panel: NSPanel
  private let store: AppStore
  private var collapseTask: Task<Void, Never>?
  private var revealTask: Task<Void, Never>?
  private var hoverTask: Task<Void, Never>?
  private var observers: [NSObjectProtocol] = []
  var screen: NSScreen {
    NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 }) ?? NSScreen.screens.first!
  }
  var notchWidth: CGFloat {
    if let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea {
      return max(160, right.minX - left.maxX)
    }
    return 90
  }
  var minimumCompactWidth: CGFloat { screen.safeAreaInsets.top > 0 ? notchWidth + 56 : 140 }
  var compactWidth: CGFloat {
    min(max(minimumCompactWidth, store.preferences.notchCompactWidth ?? Double(minimumCompactWidth + 16)), screen.frame.width - 24)
  }
  var expandedWidth: CGFloat {
    min(max(360, store.preferences.notchExpandedWidth ?? 440), screen.frame.width - 24)
  }
  init(store: AppStore) {
    self.store = store
    panel = NSPanel(
      contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered,
      defer: false)
    panel.title = "群岛 · 刘海"
    panel.isOpaque = false
    panel.backgroundColor = .clear
    panel.hasShadow = false
    panel.hidesOnDeactivate = false
    panel.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
    panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
    panel.isMovable = false
    panel.isReleasedWhenClosed = false
    let host = HoverHostingView(rootView: NotchView(controller: self).environmentObject(store))
    host.onEnter = { [weak self] in
      guard let self, self.store.preferences.hover else { return }
      self.collapseTask?.cancel()
      self.hoverTask?.cancel()
      self.hoverTask = Task {
        try? await Task.sleep(nanoseconds: 120_000_000)
        guard !Task.isCancelled else { return }
        self.expand()
      }
    }
    host.onExit = { [weak self] in
      self?.hoverTask?.cancel()
      self?.scheduleCollapse()
    }
    host.sizingOptions = []
    panel.contentView = host
    observers.append(
      NotificationCenter.default.addObserver(
        forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
      ) { [weak self] _ in Task { @MainActor in self?.layout() } })
    observers.append(
      NSWorkspace.shared.notificationCenter.addObserver(
        forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
      ) { [weak self] _ in
        Task { @MainActor in
          guard let self else { return }
          self.layout()
          if self.store.running { self.store.start() }
        }
      })
    layout()
    panel.orderFrontRegardless()
    Self.shared = self
    store.onAttention = { [weak self] in self?.flash() }
  }
  func layout(animated: Bool = false) {
    let width = expanded ? expandedWidth : compactWidth
    let count = store.pendingFocusCount
    let desiredHeight: CGFloat = count == 0 ? 270 : 450
    let height = expanded ? min(desiredHeight, screen.visibleFrame.height - 20) : max(32, screen.safeAreaInsets.top)
    let frame = NSRect(x: screen.frame.midX - width / 2, y: screen.frame.maxY - height,
                       width: width, height: height)
    if animated && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
      NSAnimationContext.runAnimationGroup { context in
        context.duration = expanded ? 0.28 : 0.22
        context.timingFunction = CAMediaTimingFunction(controlPoints: 0.22, 0.8, 0.25, 1)
        panel.animator().setFrame(frame, display: true)
      }
    } else { panel.setFrame(frame, display: true) }
  }
  func expand(pin: Bool = false) {
    collapseTask?.cancel()
    if pin { pinned = true }
    guard !expanded else { return }
    revealTask?.cancel()
    expanded = true
    layout(animated: true)
    revealTask = Task {
      if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
        try? await Task.sleep(nanoseconds: 230_000_000)
      }
      guard !Task.isCancelled, expanded else { return }
      withAnimation(.easeOut(duration: 0.12)) { contentVisible = true }
    }
  }
  func toggle() { if pinned { collapse() } else { expand(pin: true) } }
  func togglePin() {
    pinned.toggle()
    if pinned { collapseTask?.cancel() }
    else if !panel.frame.contains(NSEvent.mouseLocation) { scheduleCollapse() }
  }
  func collapse() {
    collapseTask?.cancel()
    revealTask?.cancel()
    hoverTask?.cancel()
    pinned = false
    contentVisible = false
    expanded = false
    layout(animated: true)
  }
  func scheduleCollapse() {
    guard !pinned else { return }
    collapseTask?.cancel()
    collapseTask = Task {
      try? await Task.sleep(nanoseconds: 350_000_000)
      guard !Task.isCancelled, !pinned, !panel.frame.contains(NSEvent.mouseLocation) else { return }
      collapse()
    }
  }
  func flash() {
    guard !store.isQuiet else { return }
    expand()
    layout(animated: true)
    collapseTask = Task {
      try? await Task.sleep(nanoseconds: 6_000_000_000)
      guard !Task.isCancelled, !pinned, !panel.frame.contains(NSEvent.mouseLocation) else { return }
      collapse()
    }
  }

}
private class HoverHostingView<Content: View>: NSHostingView<Content> {
  var onEnter: (() -> Void)?, onExit: (() -> Void)?
  private var tracking: NSTrackingArea?
  override func updateTrackingAreas() {
    super.updateTrackingAreas()
    if let tracking { removeTrackingArea(tracking) }
    let next = NSTrackingArea(
      rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self,
      userInfo: nil)
    addTrackingArea(next)
    tracking = next
  }
  override func mouseEntered(with event: NSEvent) { onEnter?() }
  override func mouseExited(with event: NSEvent) { onExit?() }
  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
struct NotchView: View {
  @ObservedObject var controller: NotchController
  @EnvironmentObject var store: AppStore

  var body: some View {
    VStack(spacing: 0) {
      Button {
        controller.toggle()
      } label: {
        HStack(spacing: 0) {
          Image(systemName: "circle.bottomhalf.filled").font(.system(size: 12, weight: .semibold))
            .foregroundStyle(store.running ? Color.mint : .gray)
            .frame(maxWidth: .infinity)
          Color.clear.frame(width: controller.screen.safeAreaInsets.top > 0 ? controller.notchWidth : 50)
          HStack(spacing: 4) {
            if controller.pinned { Image(systemName: "pin.fill").font(.system(size: 9)) }
            Text(store.pendingFocusCount == 0 ? "·" : "\(store.pendingFocusCount)")
              .font(.system(size: 11, weight: .semibold, design: .rounded)).monospacedDigit()
          }.foregroundStyle(Color(red: 0.75, green: 0.77, blue: 1)).frame(maxWidth: .infinity)
        }.padding(.horizontal, 8).frame(height: max(32, controller.screen.safeAreaInsets.top))
          .contentShape(Rectangle())
          .accessibilityLabel("群岛，\(store.running ? "正在监听" : "已暂停")，\(store.pendingFocusCount) 条待关注内容。点击固定或收起")
      }.buttonStyle(.plain)
      if controller.expanded {
        VStack(alignment: .leading, spacing: 14) {
          HStack {
            Text("需要关注").font(.headline)
            Spacer()
            Button {
              controller.togglePin()
            } label: {
              Image(systemName: controller.pinned ? "pin.fill" : "pin")
            }.buttonStyle(.plain).foregroundStyle(.secondary)
              .help(controller.pinned ? "取消固定" : "固定刘海")
            Button { controller.collapse() } label: { Image(systemName: "chevron.up") }
              .buttonStyle(.plain).foregroundStyle(.secondary).help("收起刘海")
          }
          AttentionBrowser(compact: true)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
          HStack {
            Text(store.analyzing ? "正在合并分析…" : store.queueDescription).font(.caption2)
              .foregroundStyle(.secondary)
            Spacer()
            Button("打开主窗口 ↗") {
              store.page = .attention
              AppDelegate.shared?.showMain()
              controller.collapse()
            }.font(.caption)
          }
        }.padding(10).opacity(controller.contentVisible ? 1 : 0)
          .allowsHitTesting(controller.contentVisible)
      }
    }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top).background(
      .black,
      in: UnevenRoundedRectangle(
        bottomLeadingRadius: controller.expanded ? 25 : 15,
        bottomTrailingRadius: controller.expanded ? 25 : 15)
    ).clipped().preferredColorScheme(.dark)
      .onChange(of: store.preferences.notchCompactWidth) { _, _ in controller.layout() }
      .onChange(of: store.preferences.notchExpandedWidth) { _, _ in controller.layout() }
      .onChange(of: store.pendingFocusCount) { _, _ in controller.layout(animated: true)
      }
  }
  func empty(_ title: String, _ text: String) -> some View {
    VStack(spacing: 12) {
      Image(systemName: "checkmark.bubble").font(.largeTitle).foregroundStyle(.secondary)
      Text(title)
      Text(text).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
    }.frame(maxWidth: .infinity).padding(.vertical, 35)
  }
}
