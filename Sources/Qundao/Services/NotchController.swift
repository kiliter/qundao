import AppKit
import Observation
import QundaoCore
import QuartzCore
import SwiftUI

/// 刘海控制器。
///
/// 性能要点：
/// - 黑色形状由 CAShapeLayer 遮罩驱动，使用 CASpringAnimation 在渲染服务器上插值，
///   动画期间主线程不参与逐帧计算，即使主线程短暂繁忙也不掉帧。
/// - 工具条与展开内容是两个独立的 NSHostingView，尺寸在动画期间保持不变，
///   SwiftUI 不会逐帧重新布局；展开内容常驻，展开时不再现场构建视图树。
/// - 内容淡入淡出用图层 alpha 动画，同样不经过 SwiftUI。
/// - 屏幕参数缓存，只在屏幕变化或唤醒时重新计算。
@MainActor @Observable final class NotchController {
  @ObservationIgnored static var shared: NotchController?
  private(set) var expanded = false
  var pinned = false
  private(set) var contentVisible = false
  @ObservationIgnored private let panel: NSPanel
  @ObservationIgnored private let store: AppStore
  @ObservationIgnored private var container: NotchContainerView!
  @ObservationIgnored private var collapseTask: Task<Void, Never>?
  @ObservationIgnored private var revealTask: Task<Void, Never>?
  @ObservationIgnored private var hoverTask: Task<Void, Never>?
  @ObservationIgnored private var shrinkTask: Task<Void, Never>?
  @ObservationIgnored private var observers: [NSObjectProtocol] = []
  /// 面板外框（窗口）尺寸：动画开始前放大到收起与展开的外包络，动画结束后再收缩。
  @ObservationIgnored private var envelope: CGSize = .zero
  static let animationDuration = 0.32
  static let bounce = 0.14
  var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

  struct ScreenMetrics: Equatable {
    var frame: CGRect, visibleHeight: CGFloat, hasNotch: Bool, notchWidth: CGFloat, barHeight: CGFloat
  }
  private(set) var metrics: ScreenMetrics
  private static func measure() -> ScreenMetrics {
    let screen = NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 }) ?? NSScreen.main ?? NSScreen.screens[0]
    var notch: CGFloat = 90
    if let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea { notch = max(160, right.minX - left.maxX) }
    return ScreenMetrics(frame: screen.frame, visibleHeight: screen.visibleFrame.height,
                         hasNotch: screen.safeAreaInsets.top > 0, notchWidth: notch,
                         barHeight: max(32, screen.safeAreaInsets.top))
  }
  var notchWidth: CGFloat { metrics.notchWidth }
  var barHeight: CGFloat { metrics.barHeight }
  var barLayout: NotchBarLayout {
    NotchBarLayout(centerWidth: metrics.hasNotch ? notchWidth : 50,
                   screenWidth: metrics.frame.width, hasNotch: metrics.hasNotch,
                   preferredCompactWidth: store.preferences.notchCompactWidth,
                   preferredExpandedWidth: store.preferences.notchExpandedWidth,
                   active: store.activity.phase.isActive, count: store.pendingFocusCount)
  }
  var minimumCompactWidth: CGFloat { barLayout.minimumCompactWidth }
  var barWidth: CGFloat { barLayout.barWidth(expanded: expanded) }
  /// 展开面板固定区：剪报标题、状态条、底栏。
  static let headerHeight: CGFloat = 64
  static let statusHeight: CGFloat = 46
  static let footerHeight: CGFloat = 38
  var compactWidth: CGFloat { barLayout.compactWidth }
  var expandedWidth: CGFloat { barLayout.expandedWidth }
  /// 列表实测高度（展开某群后会变高）；尚未测量时按行数估算。
  @ObservationIgnored private(set) var measuredListHeight: CGFloat?
  var maxListHeight: CGFloat {
    max(120, metrics.visibleHeight - 20 - barHeight - Self.headerHeight - Self.statusHeight - Self.footerHeight)
  }
  /// 标题区 + 列表内容 + 底栏，内容有多少显示多少，只有超过屏幕可用高度才在列表内滚动。
  var expandedHeight: CGFloat {
    let rows = store.pendingAttention.threads.count
    let estimate: CGFloat = CGFloat(rows) * 112 + 20
    // 测量值至少保留一行高度，避免列表被压成 0 后再也测不到真实内容。
    let content: CGFloat = rows == 0 ? 150 : min(maxListHeight, max(90, measuredListHeight ?? estimate))
    return min(barHeight + Self.headerHeight + Self.statusHeight + content + Self.footerHeight, metrics.visibleHeight - 20)
  }
  func listMeasured(_ height: CGFloat) {
    // 尚未排版时 preference 会给出默认 0，忽略。
    guard height > 1 else { return }
    guard abs((measuredListHeight ?? -100) - height) > 1 else { return }
    measuredListHeight = height
    contentChanged()
  }
  var shapeSize: CGSize {
    expanded ? CGSize(width: expandedWidth, height: expandedHeight) : CGSize(width: compactWidth, height: barHeight)
  }
  var shapeRadius: CGFloat { expanded ? 22 : 14 }

  init(store: AppStore) {
    self.store = store
    metrics = Self.measure()
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
    let bar = NSHostingView(rootView: AnyView(NotchBar(controller: self).environment(store)))
    let content = NSHostingView(rootView: AnyView(NotchExpandedContent(controller: self).environment(store)))
    for host in [bar, content] {
      host.sizingOptions = []
      host.safeAreaRegions = []
      host.wantsLayer = true
      host.layer?.backgroundColor = .clear
      host.appearance = NSAppearance(named: .darkAqua)
    }
    container = NotchContainerView(bar: bar, content: content)
    container.onEnter = { [weak self] in
      guard let self, self.store.preferences.hover else { return }
      self.collapseTask?.cancel()
      self.hoverTask?.cancel()
      self.hoverTask = Task {
        try? await Task.sleep(nanoseconds: 120_000_000)
        guard !Task.isCancelled else { return }
        self.expand()
      }
    }
    container.onExit = { [weak self] in
      self?.hoverTask?.cancel()
      self?.scheduleCollapse()
    }
    container.shapeRect = { [weak self] bounds in
      guard let self else { return bounds }
      let size = self.shapeSize
      return NSRect(x: bounds.midX - size.width / 2, y: bounds.maxY - size.height, width: size.width, height: size.height)
    }
    panel.contentView = container
    observers.append(
      NotificationCenter.default.addObserver(
        forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
      ) { [weak self] _ in Task { @MainActor in self?.screenChanged() } })
    observers.append(
      NSWorkspace.shared.notificationCenter.addObserver(
        forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
      ) { [weak self] _ in
        Task { @MainActor in
          guard let self else { return }
          self.screenChanged()
          if self.store.running { self.store.start() }
        }
      })
    layout()
    panel.orderFrontRegardless()
    Self.shared = self
    store.onAttention = { [weak self] in self?.flash() }
    observeSizes()
  }

  /// 宽度设置与行数变化时调整形状；用 Observation 跟踪，不依赖某个视图是否在显示。
  private func observeSizes() {
    withObservationTracking {
      _ = compactWidth; _ = expandedWidth; _ = barWidth; _ = store.pendingAttention.threads.count
    } onChange: { [weak self] in
      Task { @MainActor in
        guard let self else { return }
        self.contentChanged(force: true)
        self.observeSizes()
      }
    }
  }
  private func screenChanged() {
    let next = Self.measure()
    if next != metrics { metrics = next }
    layout()
  }

  /// 立即把窗口、宿主与遮罩设置为当前状态，无动画。
  func layout() {
    shrinkTask?.cancel()
    setEnvelope(shapeSize)
    lastShape = shapeSize
    container.setShape(size: shapeSize, radius: shapeRadius, animated: false)
  }
  /// 最近一次设定的目标形状尺寸。
  @ObservationIgnored private var lastShape: CGSize = .zero
  private func setEnvelope(_ size: CGSize) {
    envelope = size
    let frame = NSRect(x: metrics.frame.midX - size.width / 2, y: metrics.frame.maxY - size.height,
                       width: size.width, height: size.height)
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    if panel.frame != frame { panel.setFrame(frame, display: false) }
    container.place(barSize: CGSize(width: barWidth, height: barHeight),
                    contentSize: CGSize(width: expandedWidth, height: max(0, expandedHeight - barHeight)))
    CATransaction.commit()
    container.updateTrackingAreas()
  }
  /// 外框先放大到外包络，再在渲染服务器上做形状动画；收缩在动画结束后进行。
  private func animateShape() {
    let target = shapeSize
    guard !reduceMotion else { layout(); return }
    lastShape = target
    shrinkTask?.cancel()
    setEnvelope(CGSize(width: max(envelope.width, target.width), height: max(envelope.height, target.height)))
    let settle = container.setShape(size: target, radius: shapeRadius, animated: true)
    PerfProbe.notchAnimation(expanded ? "展开" : "收起", duration: settle)
    shrinkTask = Task {
      try? await Task.sleep(nanoseconds: UInt64(settle * 1_000_000_000))
      guard !Task.isCancelled else { return }
      self.setEnvelope(self.shapeSize)
    }
  }
  func expand(pin: Bool = false) {
    collapseTask?.cancel()
    if pin { pinned = true }
    guard !expanded else { return }
    revealTask?.cancel()
    expanded = true
    animateShape()
    container.setContentVisible(true, animated: !reduceMotion, delay: reduceMotion ? 0 : 0.12)
    contentVisible = true
  }
  func toggle() { if pinned { collapse() } else { expand(pin: true) } }
  func togglePin() {
    pinned.toggle()
    if pinned { collapseTask?.cancel() }
    else if !mouseInside { scheduleCollapse() }
  }
  private var mouseInside: Bool {
    let size = shapeSize
    let rect = NSRect(x: metrics.frame.midX - size.width / 2, y: metrics.frame.maxY - size.height,
                      width: size.width, height: size.height)
    return rect.contains(NSEvent.mouseLocation)
  }
  func collapse() {
    collapseTask?.cancel()
    revealTask?.cancel()
    hoverTask?.cancel()
    pinned = false
    guard expanded else { return }
    contentVisible = false
    container.setContentVisible(false, animated: !reduceMotion, delay: 0)
    expanded = false
    animateShape()
  }
  func scheduleCollapse() {
    guard !pinned else { return }
    collapseTask?.cancel()
    collapseTask = Task {
      try? await Task.sleep(nanoseconds: 350_000_000)
      guard !Task.isCancelled, !pinned, !mouseInside else { return }
      collapse()
    }
  }
  func flash() {
    guard !store.isQuiet else { return }
    expand()
    collapseTask = Task {
      try? await Task.sleep(nanoseconds: 6_000_000_000)
      guard !Task.isCancelled, !pinned, !mouseInside else { return }
      collapse()
    }
  }
  /// 行数、宽度或列表高度变化时平滑调整形状。
  func contentChanged(force: Bool = false) {
    guard expanded || force else { return }
    // 列表高度回报、行数与流水线显隐常在几毫秒内先后变化；合并到下一帧只做一次形状动画，
    // 避免反复重设窗口外框、调整内容宿主尺寸并重启弹簧（会掉帧）。
    guard !shapeUpdatePending else { return }
    shapeUpdatePending = true
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.016) { [weak self] in
      guard let self else { return }
      self.shapeUpdatePending = false
      // 处理状态每次变化都会触发观察；只有形状尺寸真正改变才做动画。
      guard self.shapeSize != self.lastShape else {
        // 展开时调整收起宽度或计数改变，遮罩可不变，但工具条宿主必须同步尺寸。
        self.setEnvelope(self.envelope)
        return
      }
      // 收起态宽度随处理状态变化，同样走遮罩弹簧动画。
      self.animateShape()
    }
  }
  @ObservationIgnored private var shapeUpdatePending = false
}

/// 承载工具条与展开内容，并用形状遮罩裁剪；透明外包络部分不响应点击和悬停。
private final class NotchContainerView: NSView {
  var onEnter: (() -> Void)?, onExit: (() -> Void)?
  var shapeRect: ((NSRect) -> NSRect)?
  private let bar: NSView, content: NSView
  private let shape = CAShapeLayer()
  private var tracking: NSTrackingArea?
  private var inside = false
  init(bar: NSView, content: NSView) {
    self.bar = bar; self.content = content
    super.init(frame: .zero)
    wantsLayer = true
    layer?.backgroundColor = NSColor.black.cgColor
    // 遮罩以顶部中点为原点、y 向下，外包络变化时路径坐标不变。
    shape.isGeometryFlipped = true
    shape.fillColor = NSColor.black.cgColor
    shape.bounds = .zero
    shape.actions = ["position": NSNull(), "bounds": NSNull(), "path": NSNull()]
    layer?.mask = shape
    addSubview(content)
    addSubview(bar)
    // 不用 isHidden：隐藏的宿主不排版也不更新 preference，列表高度会测不到。
    // 收起时 alpha 为 0、命中测试排除内容区，窗口也缩回工具条大小。
    content.alphaValue = 0
  }
  required init?(coder: NSCoder) { fatalError("不使用归档初始化") }
  override var isFlipped: Bool { false }
  /// 宿主尺寸固定，只随外包络重新定位，不重新排版。
  func place(barSize: CGSize, contentSize: CGSize) {
    let top = bounds.maxY
    bar.frame = NSRect(x: (bounds.width - barSize.width) / 2, y: top - barSize.height, width: barSize.width, height: barSize.height)
    content.frame = NSRect(x: (bounds.width - contentSize.width) / 2, y: top - barSize.height - contentSize.height,
                           width: contentSize.width, height: contentSize.height)
  }
  override func layout() {
    super.layout()
    CATransaction.begin(); CATransaction.setDisableActions(true)
    shape.position = CGPoint(x: bounds.midX, y: bounds.maxY)
    CATransaction.commit()
  }
  override func setFrameSize(_ newSize: NSSize) {
    super.setFrameSize(newSize)
    CATransaction.begin(); CATransaction.setDisableActions(true)
    shape.position = CGPoint(x: bounds.midX, y: bounds.maxY)
    CATransaction.commit()
  }
  /// 固定元素结构（直线 + 两段三次曲线）保证不同半径之间可插值。
  private static func path(size: CGSize, radius: CGFloat) -> CGPath {
    let w = size.width / 2, h = size.height, r = min(radius, h, w), k = r * 0.5523
    let p = CGMutablePath()
    p.move(to: CGPoint(x: -w, y: 0))
    p.addLine(to: CGPoint(x: w, y: 0))
    p.addLine(to: CGPoint(x: w, y: h - r))
    p.addCurve(to: CGPoint(x: w - r, y: h), control1: CGPoint(x: w, y: h - r + k), control2: CGPoint(x: w - r + k, y: h))
    p.addLine(to: CGPoint(x: -w + r, y: h))
    p.addCurve(to: CGPoint(x: -w, y: h - r), control1: CGPoint(x: -w + r - k, y: h), control2: CGPoint(x: -w, y: h - r + k))
    p.closeSubpath()
    return p
  }
  /// 返回动画稳定所需时间。
  @discardableResult func setShape(size: CGSize, radius: CGFloat, animated: Bool) -> Double {
    let target = Self.path(size: size, radius: radius)
    guard animated else {
      shape.removeAllAnimations()
      CATransaction.begin(); CATransaction.setDisableActions(true)
      shape.path = target
      CATransaction.commit()
      return 0
    }
    let from = shape.presentation()?.path ?? shape.path
    let spring = CASpringAnimation(perceptualDuration: NotchController.animationDuration, bounce: NotchController.bounce)
    spring.keyPath = "path"
    spring.fromValue = from
    spring.toValue = target
    spring.duration = spring.settlingDuration
    CATransaction.begin(); CATransaction.setDisableActions(true)
    shape.path = target
    CATransaction.commit()
    shape.add(spring, forKey: "path")
    return spring.settlingDuration
  }
  private var fadeToken = 0
  func setContentVisible(_ visible: Bool, animated: Bool, delay: Double) {
    fadeToken += 1
    let token = fadeToken
    guard animated else {
      content.alphaValue = visible ? 1 : 0
      return
    }
    let run = { [weak self] in
      guard let self, self.fadeToken == token else { return }
      NSAnimationContext.runAnimationGroup({ ctx in
        ctx.duration = visible ? 0.16 : 0.08
        ctx.timingFunction = CAMediaTimingFunction(name: visible ? .easeOut : .easeIn)
        self.content.animator().alphaValue = visible ? 1 : 0
      })
    }
    if delay > 0 { DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: run) } else { run() }
  }
  override func updateTrackingAreas() {
    super.updateTrackingAreas()
    if let tracking { removeTrackingArea(tracking) }
    let next = NSTrackingArea(
      rect: bounds, options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect], owner: self,
      userInfo: nil)
    addTrackingArea(next)
    tracking = next
  }
  private func update(_ event: NSEvent) {
    let point = convert(event.locationInWindow, from: nil)
    let now = (shapeRect?(bounds) ?? bounds).contains(point)
    guard now != inside else { return }
    inside = now
    if now { onEnter?() } else { onExit?() }
  }
  override func mouseEntered(with event: NSEvent) { update(event) }
  override func mouseMoved(with event: NSEvent) { update(event) }
  override func mouseExited(with event: NSEvent) {
    if inside { inside = false; onExit?() }
  }
  override func hitTest(_ point: NSPoint) -> NSView? {
    let local = convert(point, from: superview)
    guard (shapeRect?(bounds) ?? bounds).contains(local) else { return nil }
    return super.hitTest(point)
  }
  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

// MARK: - P5 风格视图

extension IslandActivity {
  /// 收起态左翼的短标签；空闲与暂停不显示。
  func compactLabel(now: Date) -> String? {
    switch phase {
    case .idle, .paused: return nil
    case .buffering:
      guard let deadline = buffer.deadline else { return "缓冲" }
      return String(format: "%.0fs", max(0, deadline.timeIntervalSince(now)).rounded(.up))
    case .judging: return "Jev"
    case .loading: return "读取"
    case .summarizing: return summaries.count > 1 ? "AI ×\(summaries.count)" : "AI"
    case .waiting: return "等 \(immediateWaiting + periodicWaiting)"
    case .retrying:
      guard let retryAt else { return "重试" }
      return "\(Int(max(0, retryAt.timeIntervalSince(now)).rounded(.up)))s"
    case .attention: return "+1"
    }
  }
  var needsClock: Bool { phase == .buffering || phase == .retrying || !buffer.isEmpty || retryAt != nil }
  var accessibilityText: String {
    switch phase {
    case .paused: "已暂停"
    case .idle: "空闲"
    case .buffering: "缓冲中，\(buffer.count) 条消息等待提交"
    case .judging: "Jev 正在判断"
    case .loading: "正在读取群未读"
    case .summarizing: "AI 正在摘要 \(summaries.count) 个群"
    case .waiting: "\(immediateWaiting + periodicWaiting) 个摘要任务排队"
    case .retrying: "摘要或判断失败，等待重试"
    case .attention: "有新的关注内容"
    }
  }
  /// 状态牌：标题 + 明细。
  func plate(now: Date, usesJev: Bool, lastAnalysis: Date?, queue: String) -> (title: String, detail: String) {
    switch phase {
    case .paused: return ("已暂停", "监听已暂停")
    case .idle:
      if let lastAnalysis { return ("空闲", "全部处理完毕 · 上次摘要 \(lastAnalysis.formatted(.dateTime.hour().minute()))") }
      return ("空闲", "全部处理完毕")
    case .buffering:
      let left = buffer.deadline.map { max(0, $0.timeIntervalSince(now)) } ?? 0
      return ("缓冲中", buffer.count >= buffer.capacity ? "\(buffer.count) 条 · 容量已满"
        : "\(buffer.count) 条 · \(String(format: "%.1f", left))s 后提交")
    case .judging:
      let rest = judgeBatches > 1 ? " · 余 \(judgeBatches - 1) 批" : ""
      return (usesJev ? "Jev 判断" : "本地识别", "\(judgingGroupName ?? "相关性") 判断中\(rest)")
    case .loading:
      return ("AI摘要", "\(summaries.first?.groupName ?? "群聊") · 读取全部未读")
    case .summarizing:
      if summaries.count > 1 { return ("AI摘要", "\(summaries.count)/\(concurrency) 个群同时摘要") }
      let first = summaries.first
      return ("AI摘要", "\(first?.groupName ?? "群聊") · \(first?.messages ?? 0) 条未读 · 第 \(max(1, first?.requests ?? 1)) 次请求")
    case .waiting: return ("排队中", queue)
    case .retrying:
      let left = retryAt.map { Int(max(0, $0.timeIntervalSince(now)).rounded(.up)) } ?? 0
      return ("失败重试", "\(left)s 后重试 · 进度未推进")
    case .attention: return ("新关注", "已生成新的关注内容")
    }
  }
  /// 三段流水线各自是否在进行（可并行点亮）。
  var stages: (buffer: Bool, judge: Bool, summary: Bool) {
    (!buffer.isEmpty, judging || (judgeBatches > 0 && phase == .judging), !summaries.isEmpty)
  }
  var hot: Bool { [.buffering, .judging, .loading, .summarizing, .attention].contains(phase) }
}

/// 收起态 / 状态牌徽记：四角星；处理中旋转，空闲为灰，失败反向慢转。
private struct P5Emblem: View {
  let phase: IslandPhase
  var size: CGFloat = 16
  var animate = true
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  var body: some View {
    let moving = animate && !reduceMotion && phase.isActive && phase != .attention
    let speed: Double = switch phase {
    case .summarizing, .loading: 400
    case .judging: 260
    case .retrying: -120
    default: 150
    }
    TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !moving)) { context in
      let angle = moving ? context.date.timeIntervalSinceReferenceDate * speed : 0
      P5Spark()
        .fill(fill)
        .overlay(P5Spark().stroke(.white, lineWidth: 1))
        .frame(width: size, height: size)
        .rotationEffect(.degrees(angle.truncatingRemainder(dividingBy: 360)))
    }
    .scaleEffect(phase == .attention && !reduceMotion ? 1.25 : 1)
    .animation(reduceMotion ? nil : P5.pop, value: phase)
    .accessibilityHidden(true)
  }
  private var fill: Color {
    switch phase {
    case .idle: Color(white: 0.24)
    case .paused, .waiting: Color(white: 0.4)
    case .retrying: Color(white: 0.55)
    default: P5.red
    }
  }
}

private struct NotchBar: View {
  let controller: NotchController
  @Environment(AppStore.self) var store
  var body: some View {
    NotchBarContent(activity: store.activity, count: store.pendingFocusCount,
                    expanded: controller.expanded, pinned: controller.pinned,
                    layout: controller.barLayout, toggle: controller.toggle)
  }
}

/// 不读取配置或聊天数据的展示组件，可用合成状态验证真实 SwiftUI 排版。
struct NotchBarContent: View {
  let activity: IslandActivity
  let count: Int
  let expanded: Bool
  let pinned: Bool
  let layout: NotchBarLayout
  var toggle: () -> Void = {}
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  var body: some View {
    Button(action: toggle) {
      HStack(spacing: 0) {
        // 只有缓冲倒计时 / 重试倒数需要时钟；空闲时暂停。
        TimelineView(.animation(minimumInterval: 0.25, paused: !activity.needsClock || expanded)) { context in
          HStack(spacing: 6) {
            P5Emblem(phase: activity.phase, animate: !expanded)
            if !expanded, let label = activity.compactLabel(now: activity.needsClock ? context.date : Date()) {
              Text(label).font(P5.heavy(11)).monospacedDigit().foregroundStyle(.white).lineLimit(1).minimumScaleFactor(0.6)
                .padding(.horizontal, 7).padding(.vertical, 2.5)
                .background(activity.phase == .retrying ? Color(white: 0.3) : P5.red, in: P5Slant(slant: 0.16))
                .transition(.scale(scale: 0.2, anchor: .leading).combined(with: .opacity))
            }
          }
        }
        .padding(.horizontal, 8)
        .frame(width: layout.wingWidth(expanded: expanded))
        .clipped()
        Color.clear.frame(width: layout.centerWidth)
        HStack(spacing: 4) {
          if pinned { P5Spark().fill(P5.red).frame(width: 8, height: 8) }
          Text(verbatim: count == 0 ? "—" : "\(count)")
            .font(P5.numeral(13))
            .lineLimit(1).minimumScaleFactor(0.5)
            .contentTransition(.numericText(value: Double(count)))
            .foregroundStyle(count == 0 ? Color(white: 0.4) : (activity.phase == .attention ? P5.red : .white))
            .scaleEffect(activity.phase == .attention && !reduceMotion ? 1.35 : 1)
        }
        .padding(.horizontal, 8)
        .frame(width: layout.wingWidth(expanded: expanded))
        .clipped()
      }.frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .animation(reduceMotion ? nil : P5.pop, value: count)
        .animation(reduceMotion ? nil : P5.snap, value: activity.phase)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("群岛，\(activity.accessibilityText)，\(count) 条待关注内容。点击固定或收起")
    }.buttonStyle(.plain)
  }
}

/// 状态条：斜切状态牌（切换时从左侧打出）+ 三段箭头流水线 + 缓冲倒计时条。
private struct P5StatusStrip: View {
  let activity: IslandActivity
  let interval: Double
  let usesJev: Bool
  let lastAnalysis: Date?
  let queue: String
  let animate: Bool
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  var body: some View {
    TimelineView(.animation(minimumInterval: 0.1, paused: !activity.needsClock || !animate)) { context in
      let now = activity.needsClock ? context.date : Date()
      let plate = activity.plate(now: now, usesJev: usesJev, lastAnalysis: lastAnalysis, queue: queue)
      let stages = activity.stages
      VStack(alignment: .leading, spacing: 5) {
        HStack(spacing: 8) {
          HStack(spacing: 7) {
            Text(plate.title).font(P5.heavy(13)).kerning(1).fixedSize()
            Text(plate.detail).font(.system(size: 10.5, weight: .medium)).monospacedDigit().lineLimit(1)
              .foregroundStyle(activity.hot ? Color.white.opacity(0.82) : Color(white: 0.3))
          }
          .foregroundStyle(activity.hot ? .white : .black)
          .padding(.leading, 10).padding(.trailing, 16).frame(height: 28)
          .background(activity.hot ? P5.red : .white, in: P5Slant(slant: -0.035))
          .id(activity.phase)
          .transition(reduceMotion ? .opacity : .asymmetric(
            insertion: .scale(scale: 0.05, anchor: .leading).combined(with: .opacity), removal: .opacity))
          .layoutPriority(1)
          Spacer(minLength: 0)
          HStack(spacing: 2) {
            chevron("缓冲中", on: stages.buffer, first: true)
            chevron(usesJev ? "Jev 判断" : "本地识别", on: stages.judge, first: false)
            chevron("AI摘要", on: stages.summary, dim: activity.phase == .retrying, first: false)
          }.fixedSize()
        }.frame(height: 30)
        GeometryReader { proxy in
          let fraction = activity.buffer.deadline.map { max(0, min(1, $0.timeIntervalSince(now) / max(0.1, interval))) } ?? 0
          ZStack(alignment: .leading) {
            Rectangle().fill(Color(white: 0.14))
            Rectangle().fill(P5.red).frame(width: proxy.size.width * fraction)
          }.transformEffect(CGAffineTransform(a: 1, b: 0, c: -0.6, d: 1, tx: 0, ty: 0))
        }.frame(height: 3).opacity(activity.buffer.isEmpty ? 0 : 1)
      }
    }
    .animation(reduceMotion ? nil : P5.snap, value: activity.phase)
    .accessibilityElement(children: .combine)
  }
  private func chevron(_ title: String, on: Bool, dim: Bool = false, first: Bool) -> some View {
    Text(title).font(P5.heavy(9.5)).lineLimit(1)
      .foregroundStyle(on ? .white : (dim ? Color(white: 0.75) : Color(white: 0.45)))
      .padding(.leading, first ? 9 : 12).padding(.trailing, 11).frame(height: 22)
      .background(on ? P5.red : (dim ? Color(white: 0.24) : Color(white: 0.12)), in: P5Chevron(first: first))
  }
}

/// 斜切小按钮：黑底白字，悬停反白。
private struct P5Button<Label: View>: View {
  let help: String
  let action: () -> Void
  @ViewBuilder let label: () -> Label
  @State private var hovering = false
  var body: some View {
    Button(action: action) {
      label().foregroundStyle(hovering ? Color.black : .white)
        .background(hovering ? Color.white : .black, in: P5Slant(slant: 0.12))
    }.buttonStyle(.plain).onHover { hovering = $0 }.help(help).accessibilityLabel(help)
  }
}

/// 展开内容：剪报标题 + 爆炸星计数、状态条、群卡片、底栏，以及新关注插播。
private struct NotchExpandedContent: View {
  let controller: NotchController
  @Environment(AppStore.self) var store
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var bump = false
  var body: some View {
    let threads = store.pendingAttention.threads
    let activity = store.activity
    let count = store.pendingFocusCount
    VStack(spacing: 0) {
      HStack(alignment: .center, spacing: 8) {
        P5Ransom(text: "需要关注")
        ZStack {
          P5Burst().fill(.black).overlay(P5Burst().stroke(.white, lineWidth: 1.6))
          Text("\(count)").font(P5.numeral(count > 99 ? 12 : 16)).foregroundStyle(.white)
            .shadow(color: .black, radius: 0, x: 2, y: 2)
            .contentTransition(.numericText(value: Double(count)))
        }.frame(width: 42, height: 42)
          .rotationEffect(.degrees(bump ? 18 : 0)).scaleEffect(bump ? 1.18 : 1)
          .accessibilityLabel("\(count) 条待关注")
        Spacer()
        VStack(alignment: .trailing, spacing: 6) {
          HStack(spacing: 4) {
            P5Button(help: controller.pinned ? "取消固定" : "固定刘海", action: { controller.togglePin() }) {
              Image(systemName: controller.pinned ? "pin.fill" : "pin").font(.system(size: 9.5, weight: .bold))
                .frame(width: 24, height: 20)
            }
            P5Button(help: "收起刘海", action: { controller.collapse() }) {
              Image(systemName: "chevron.up").font(.system(size: 9.5, weight: .heavy)).frame(width: 24, height: 20)
            }
          }
          P5Button(help: "将当前账号所有待关注内容标记已阅；不改变微信未读", action: {
            store.readFocusEntries(store.pendingAttention.entries)
          }) {
            Text("一键已阅").font(P5.heavy(11)).kerning(1).padding(.horizontal, 13).frame(height: 22)
          }.disabled(threads.isEmpty).opacity(threads.isEmpty ? 0.6 : 1)
        }
      }.padding(.horizontal, 14).frame(height: NotchController.headerHeight)
      P5StatusStrip(activity: activity, interval: store.preferences.bufferInterval, usesJev: store.preferences.usesJev,
                    lastAnalysis: store.lastAnalysis, queue: store.queueDescription, animate: controller.contentVisible)
        .padding(.horizontal, 14).frame(height: NotchController.statusHeight, alignment: .top)
      if threads.isEmpty {
        VStack(spacing: 12) {
          Text("全部清空").font(P5.heavy(24)).foregroundStyle(.black)
            .padding(.horizontal, 14).padding(.vertical, 6)
            .background { ZStack { P5.red.offset(x: 6, y: 6); Color.white } }
            .rotationEffect(.degrees(-4))
          Text("白名单群有与你相关的新动向，会第一时间出现在这里").font(.caption).foregroundStyle(Color(white: 0.6))
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
      } else {
        let updating = Set(activity.summaries.map(\.group))
        ScrollView {
          LazyVStack(spacing: 14) {
            ForEach(Array(threads.enumerated()), id: \.element.id) { index, thread in
              NotchThreadRow(thread: thread, index: index, updating: updating.contains(thread.id)) {
                store.attentionGroupID = thread.id
                store.page = .attention
                AppDelegate.shared?.showMain()
                controller.collapse()
              }
              .transition(reduceMotion ? .opacity : .asymmetric(
                insertion: .move(edge: .leading).combined(with: .opacity), removal: .opacity))
            }
          }.padding(.leading, 16).padding(.trailing, 20).padding(.top, 6).padding(.bottom, 14)
            // 直接在测量视图内回报高度：preference 在这个宿主中不能从 ScrollView 内容向外传递。
            .background(GeometryReader { proxy in
              Color.clear
                .onAppear { controller.listMeasured(proxy.size.height) }
                .onChange(of: proxy.size.height) { _, height in controller.listMeasured(height) }
            })
        }.scrollIndicators(.never)
      }
      HStack(spacing: 6) {
        Text("待阅 \(count) · \(threads.count) 个群").font(.system(size: 10.5)).foregroundStyle(Color(white: 0.6)).lineLimit(1)
        Spacer()
        Button {
          store.page = .attention
          AppDelegate.shared?.showMain()
          controller.collapse()
        } label: {
          HStack(spacing: 4) { Text("打开主窗口"); Image(systemName: "play.fill").font(.system(size: 7)) }
            .font(P5.heavy(11)).foregroundStyle(.white).padding(.horizontal, 12).frame(height: 22)
            .background(P5.red, in: P5Slant(slant: 0.08))
        }.buttonStyle(.plain)
      }.padding(.horizontal, 16).frame(height: NotchController.footerHeight)
        .overlay(alignment: .top) { Rectangle().fill(Color(white: 0.11)).frame(height: 2) }
    }
    .background(P5Backdrop())
    .overlay { P5CutIn(active: activity.phase == .attention, definite: threads.first.map { thread in
      thread.entries.contains { thread.tags(for: $0).contains(where: \.definite) } } ?? false) }
    .animation(reduceMotion ? nil : .timingCurve(0.7, 0, 0.2, 1, duration: 0.36), value: threads.map(\.id))
    .onChange(of: count) { old, new in
      guard new > old, !reduceMotion else { return }
      withAnimation(P5.pop) { bump = true }
      Task { try? await Task.sleep(nanoseconds: 260_000_000); withAnimation(P5.pop) { bump = false } }
    }
    // 收起时内容仍在排版（以便测量高度），但不暴露给辅助功能、不接收点击。
    .accessibilityHidden(!controller.contentVisible)
    .allowsHitTesting(controller.contentVisible)
  }
}

/// 新关注插播：红色斜横幅从左冲入、停留、从右冲出。减少动态效果时不播放。
private struct P5CutIn: View {
  let active: Bool
  let definite: Bool
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var position: CGFloat = -1.3
  @State private var visible = false
  var body: some View {
    GeometryReader { proxy in
      if visible {
        Text(definite ? "有人找你！" : "新的关注！")
          .font(P5.heavy(26)).kerning(4).foregroundStyle(.white)
          .shadow(color: .black, radius: 0, x: 3, y: 3)
          .frame(width: proxy.size.width * 1.3, height: 60)
          .background(P5.red)
          .overlay(Rectangle().stroke(.black, lineWidth: 6))
          .padding(6).background(.white)
          .rotationEffect(.degrees(-8))
          .position(x: proxy.size.width / 2 + position * proxy.size.width, y: proxy.size.height * 0.45)
      }
    }
    .allowsHitTesting(false)
    .accessibilityHidden(true)
    .onChange(of: active) { _, now in if now { play() } }
  }
  private func play() {
    guard !reduceMotion else { return }
    position = -1.3
    visible = true
    Task { @MainActor in
      withAnimation(.timingCurve(0.7, 0, 0.2, 1, duration: 0.26)) { position = 0 }
      try? await Task.sleep(nanoseconds: 900_000_000)
      withAnimation(.timingCurve(0.7, 0, 0.2, 1, duration: 0.26)) { position = 1.3 }
      try? await Task.sleep(nanoseconds: 300_000_000)
      visible = false
    }
  }
}

/// 群头像：黑色不规则块 + 首字；悬停时变红。
private struct NotchAvatar: View {
  let name: String
  let hot: Bool
  var body: some View {
    Text(String(name.prefix(1))).font(P5.heavy(13.5)).foregroundStyle(.white)
      .frame(width: 28, height: 28)
      .background(hot ? P5.red : .black, in: P5Shard())
      .accessibilityHidden(true)
  }
}

/// 一个群一张歪斜白卡：默认只显示最新一条摘要，其余折叠；悬停翻黑并出现「本群已阅」，
/// 点击后盖「已阅」印章、斜切移除。
private struct NotchThreadRow: View {
  @Environment(AppStore.self) var store
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  let thread: AttentionThread
  let index: Int
  let updating: Bool
  let open: () -> Void
  @State private var hovering = false
  @State private var unfolded = false
  @State private var leaving = false
  @State private var sweep = false
  var body: some View {
    let latest = thread.entries[0]
    let older = thread.entries.count - 1
    let shown = unfolded ? thread.entries : [latest]
    let inverted = hovering && !leaving
    VStack(alignment: .leading, spacing: 8) {
      HStack(spacing: 9) {
        NotchAvatar(name: latest.groupName, hot: inverted)
        Text(latest.groupName).font(P5.heavy(13.5)).lineLimit(1)
        if thread.pendingCount > 1 {
          Text("×\(thread.pendingCount)").font(P5.numeral(11)).foregroundStyle(.white)
            .padding(.horizontal, 7).padding(.vertical, 2.5).background(P5.red, in: P5Slant(slant: 0.16))
        }
        if updating {
          HStack(spacing: 4) {
            Rectangle().fill(P5.red).frame(width: 6, height: 6).rotationEffect(.degrees(45))
              .opacity(sweep ? 0.2 : 1)
            Text("更新中").kerning(1)
          }.font(P5.heavy(10)).foregroundStyle(P5.red).transition(.opacity)
        }
        Spacer(minLength: 4)
        ZStack(alignment: .trailing) {
          Text(latest.date, format: .dateTime.hour().minute()).font(P5.numeral(11))
            .foregroundStyle(inverted ? Color(white: 0.6) : Color(white: 0.4)).opacity(inverted ? 0 : 1)
          Button(action: markRead) {
            Text("本群已阅").font(P5.heavy(11)).kerning(1).foregroundStyle(.white)
              .padding(.leading, 11).padding(.trailing, 14).frame(height: 22)
              .background(P5.red, in: P5Chevron(first: false))
          }.buttonStyle(.plain)
            .opacity(inverted ? 1 : 0).offset(x: inverted ? 0 : 8).allowsHitTesting(inverted)
            .help("本群已阅，不改变微信未读").accessibilityLabel("本群已阅")
        }.frame(height: 24)
      }.frame(height: 28)
      VStack(alignment: .leading, spacing: 7) {
        ForEach(Array(shown.enumerated()), id: \.element.id) { offset, entry in
          entryView(entry, offset: offset, inverted: inverted)
        }
        if older > 0 {
          Button {
            withAnimation(reduceMotion ? nil : P5.snap) { unfolded.toggle() }
          } label: {
            HStack(spacing: 4) {
              Image(systemName: unfolded ? "arrowtriangle.up.fill" : "arrowtriangle.right.fill").font(.system(size: 7))
              Text(unfolded ? "收起较早摘要" : "还有 \(older) 条较早摘要")
            }.font(P5.heavy(10.5)).foregroundStyle(P5.red).contentShape(Rectangle())
          }.buttonStyle(.plain)
        }
      }
    }
    .foregroundStyle(inverted ? .white : P5.ink)
    .padding(.leading, 18).padding(.trailing, 16).padding(.vertical, 12)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background {
      ZStack {
        // 红色错位阴影；悬停时加大并多一层白边。
        P5CardShape().fill(.white).offset(x: -3, y: -3).opacity(inverted ? 1 : 0)
        P5CardShape().fill(P5.red).offset(x: inverted ? 7 : 5, y: inverted ? 7 : 5)
        P5CardShape().fill(inverted ? Color.black : P5.paper)
        if updating && !reduceMotion {
          GeometryReader { proxy in
            LinearGradient(colors: [.clear, P5.red.opacity(0.22), .clear], startPoint: .leading, endPoint: .trailing)
              .frame(width: proxy.size.width * 0.4)
              .offset(x: sweep ? proxy.size.width : -proxy.size.width * 0.4)
          }.clipShape(P5CardShape())
        }
      }
      .rotationEffect(.degrees(index.isMultiple(of: 2) ? -0.5 : 0.6))
    }
    .overlay {
      Text("已阅").font(P5.heavy(22)).foregroundStyle(P5.red)
        .padding(.horizontal, 10).padding(.vertical, 4)
        .overlay(Rectangle().stroke(P5.red, lineWidth: 3))
        .rotationEffect(.degrees(-12))
        .scaleEffect(leaving ? 1 : 2).opacity(leaving ? 1 : 0)
        .allowsHitTesting(false)
    }
    .mask {
      // 斜切移除：遮罩从左向右收走。
      GeometryReader { proxy in
        Rectangle().offset(x: leaving ? proxy.size.width + 40 : 0)
          .animation(reduceMotion ? nil : .timingCurve(0.7, 0, 0.2, 1, duration: 0.3).delay(0.22), value: leaving)
      }.padding(-10)
    }
    .offset(x: hovering && !leaving ? -4 : 0)
    .contentShape(Rectangle())
    .onTapGesture(perform: open)
    .onHover { hovering = $0 }
    .animation(reduceMotion ? nil : .spring(duration: 0.22, bounce: 0.4), value: hovering)
    .animation(reduceMotion ? nil : .spring(duration: 0.2, bounce: 0.5), value: leaving)
    .onAppear { startSweep() }
    .onChange(of: updating) { _, _ in startSweep() }
    .accessibilityElement(children: .contain)
    .accessibilityAddTraits(.isButton)
    .accessibilityLabel("\(latest.groupName)，\(thread.pendingCount) 条待关注\(updating ? "，正在更新" : "")")
    .accessibilityHint("在主窗口打开本群")
    .accessibilityAction { open() }
    .accessibilityAction(named: "本群已阅") { markRead() }
  }

  @ViewBuilder private func entryView(_ entry: AttentionEntry, offset: Int, inverted: Bool) -> some View {
    let tags = thread.tags(for: entry)
    let rail = unfolded && thread.entries.count > 1
    HStack(alignment: .top, spacing: 0) {
      if rail {
        Rectangle().fill(offset == 0 ? P5.red : (inverted ? Color(white: 0.35) : .black)).frame(width: 3).padding(.trailing, 9)
      }
      VStack(alignment: .leading, spacing: 3) {
        if rail {
          HStack(spacing: 6) {
            if offset == 0 {
              Text("NEW").font(P5.heavy(9)).kerning(1).foregroundStyle(.white)
                .padding(.horizontal, 5).padding(.vertical, 1.5)
                .background(inverted ? P5.red : .black, in: P5Slant(slant: 0.16)).rotationEffect(.degrees(-3))
            }
            Text(entry.date, format: .dateTime.hour().minute()).font(P5.numeral(10)).foregroundStyle(Color(white: 0.5))
          }
        }
        Text(entry.preview).font(.system(size: 11.8))
          .foregroundStyle(offset > 0 ? (inverted ? Color(white: 0.62) : Color(white: 0.4)) : (inverted ? Color(white: 0.93) : P5.ink))
          .lineSpacing(3).multilineTextAlignment(.leading)
          .fixedSize(horizontal: false, vertical: true)
        if !tags.isEmpty { P5Tags(tags: tags, inverted: inverted).padding(.top, 3) }
      }
    }.frame(maxWidth: .infinity, alignment: .leading)
  }

  private func markRead() {
    guard !leaving else { return }
    let selection = store.captureFocusSelection(thread.entries)
    guard !reduceMotion else { store.readFocusSelection(selection); return }
    leaving = true
    Task { @MainActor in
      try? await Task.sleep(nanoseconds: 540_000_000)
      store.readFocusSelection(selection)
      // 同群在动画期间可能新增待阅内容，保存失败也会保留原记录；幸存行必须恢复可见。
      var transaction = Transaction()
      transaction.disablesAnimations = true
      withTransaction(transaction) { leaving = false }
    }
  }
  private func startSweep() {
    guard updating, !reduceMotion else { sweep = false; return }
    sweep = false
    withAnimation(.linear(duration: 1.1).repeatForever(autoreverses: false)) { sweep = true }
  }
}
