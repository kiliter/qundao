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
  var minimumCompactWidth: CGFloat { metrics.hasNotch ? notchWidth + 56 : 140 }
  /// 处理中时收起态两翼加宽，留出阶段标签（倒计时、Jev、摘要等）。
  static let activeExtraWidth: CGFloat = 52
  static let pipelineHeight: CGFloat = 94
  var compactWidth: CGFloat {
    let base = max(minimumCompactWidth, store.preferences.notchCompactWidth ?? Double(minimumCompactWidth + 16))
    return min(base + (store.activity.phase.isActive ? Self.activeExtraWidth : 0), metrics.frame.width - 24)
  }
  var expandedWidth: CGFloat {
    min(max(360, store.preferences.notchExpandedWidth ?? 440), metrics.frame.width - 24)
  }
  /// 列表实测高度（展开某群后会变高）；尚未测量时按行数估算。
  @ObservationIgnored private(set) var measuredListHeight: CGFloat?
  var maxListHeight: CGFloat {
    max(120, metrics.visibleHeight - 20 - barHeight - 44 - 38 - (store.activity.pipelineVisible ? Self.pipelineHeight : 0))
  }
  /// 标题区 + 列表内容 + 底栏，内容有多少显示多少，只有超过屏幕可用高度才在列表内滚动。
  var expandedHeight: CGFloat {
    let rows = store.pendingAttention.threads.count
    let estimate: CGFloat = CGFloat(rows) * 64 + 8
    // 测量值至少保留一行高度，避免列表被压成 0 后再也测不到真实内容。
    let content: CGFloat = rows == 0 ? 120 : min(maxListHeight, max(72, measuredListHeight ?? estimate))
    let pipeline: CGFloat = store.activity.pipelineVisible ? Self.pipelineHeight : 0
    return min(barHeight + 44 + pipeline + content + 38, metrics.visibleHeight - 20)
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
  var shapeRadius: CGFloat { expanded ? 24 : 14 }

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
      _ = compactWidth; _ = expandedWidth; _ = store.pendingAttention.threads.count
      _ = store.activity.pipelineVisible
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
    container.place(barSize: CGSize(width: compactWidth, height: barHeight),
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
      guard self.shapeSize != self.lastShape else { return }
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

private enum IslandColor {
  static let mint = Color(red: 0.37, green: 0.88, blue: 0.70)
  static let amber = Color(red: 1, green: 0.72, blue: 0.30)
  static let violet = Color(red: 0.66, green: 0.55, blue: 1)
  static let cyan = Color(red: 0.31, green: 0.76, blue: 1)
  static let orange = Color(red: 1, green: 0.54, blue: 0.36)
  static let grey = Color(white: 0.55)
  static let count = Color(red: 0.75, green: 0.77, blue: 1)
  static func of(_ phase: IslandPhase) -> Color {
    switch phase {
    case .idle, .attention: mint
    case .paused, .waiting: grey
    case .buffering: amber
    case .judging: violet
    case .loading, .summarizing: cyan
    case .retrying: orange
    }
  }
}

/// 阶段图形：空闲常亮点、缓冲倒计时环、Jev 跳动省略号、摘要转圈、退避箭头、新增勾号。
private struct ActivityGlyph: View {
  let phase: IslandPhase
  var deadline: Date?
  var total: Double = 3
  var animate = true
  var size: CGFloat = 14
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  var body: some View {
    let color = IslandColor.of(phase)
    let moving = animate && !reduceMotion
    ZStack {
      switch phase {
      case .idle:
        Circle().fill(color).frame(width: size * 0.43, height: size * 0.43).shadow(color: color.opacity(0.8), radius: 3)
          .transition(.scale(scale: 0.3).combined(with: .opacity))
      case .paused:
        Circle().stroke(color, lineWidth: 1.5).frame(width: size * 0.5, height: size * 0.5)
          .transition(.scale(scale: 0.3).combined(with: .opacity))
      case .buffering:
        CountdownRing(deadline: deadline, total: total, color: color, ticking: animate)
          .transition(.scale(scale: 0.3).combined(with: .opacity))
      case .judging:
        Image(systemName: "ellipsis").font(.system(size: size * 0.8, weight: .heavy)).foregroundStyle(color)
          .symbolEffect(.variableColor.iterative.dimInactiveLayers, options: .repeating, isActive: moving)
          .transition(.scale(scale: 0.3).combined(with: .opacity))
      case .waiting:
        Image(systemName: "ellipsis").font(.system(size: size * 0.8, weight: .heavy)).foregroundStyle(color)
          .symbolEffect(.pulse, options: .repeating, isActive: moving)
          .transition(.scale(scale: 0.3).combined(with: .opacity))
      case .loading, .summarizing:
        Spinner(color: color, moving: moving).transition(.scale(scale: 0.3).combined(with: .opacity))
      case .retrying:
        Image(systemName: "arrow.clockwise").font(.system(size: size * 0.72, weight: .bold)).foregroundStyle(color)
          .symbolEffect(.pulse, options: .repeating, isActive: moving)
          .transition(.scale(scale: 0.3).combined(with: .opacity))
      case .attention:
        Image(systemName: "checkmark.circle.fill").font(.system(size: size * 0.86, weight: .bold)).foregroundStyle(color)
          .transition(.scale(scale: 0.2).combined(with: .opacity))
      }
    }
    .frame(width: size, height: size)
    .animation(reduceMotion ? nil : .spring(duration: 0.35, bounce: 0.45), value: phase)
    .accessibilityHidden(true)
  }
}

/// 剩余时间环：截止时间按首条到达固定，环随时间消耗。
private struct CountdownRing: View {
  let deadline: Date?
  let total: Double
  let color: Color
  let ticking: Bool
  var body: some View {
    TimelineView(.animation(minimumInterval: 0.1, paused: !ticking || deadline == nil)) { context in
      let left = max(0, (deadline ?? context.date).timeIntervalSince(ticking ? context.date : Date()))
      let fraction = total > 0 ? min(1, left / total) : 0
      ZStack {
        Circle().stroke(Color.white.opacity(0.14), lineWidth: 2.2)
        Circle().trim(from: 0, to: fraction).stroke(color, style: StrokeStyle(lineWidth: 2.2, lineCap: .round))
          .rotationEffect(.degrees(-90))
      }.padding(1.5)
    }
  }
}

private struct Spinner: View {
  let color: Color
  let moving: Bool
  @State private var spin = false
  var body: some View {
    ZStack {
      Circle().stroke(Color.white.opacity(0.14), lineWidth: 2)
      Circle().trim(from: 0, to: 0.32).stroke(color, style: StrokeStyle(lineWidth: 2, lineCap: .round))
        .rotationEffect(.degrees(spin ? 360 : 0))
    }.padding(1.5)
      .onAppear { start() }
      .onChange(of: moving) { _, _ in start() }
  }
  private func start() {
    guard moving else { spin = false; return }
    spin = false
    withAnimation(.linear(duration: 0.85).repeatForever(autoreverses: false)) { spin = true }
  }
}

extension IslandActivity {
  /// 收起态左翼的短标签；空闲与暂停不显示。
  func compactLabel(now: Date) -> String? {
    switch phase {
    case .idle, .paused: return nil
    case .buffering:
      guard let deadline = buffer.deadline else { return "缓冲" }
      return String(format: "%.1fs", max(0, deadline.timeIntervalSince(now)))
    case .judging: return "Jev"
    case .loading: return "读取"
    case .summarizing: return summaries.count > 1 ? "摘要 \(summaries.count)" : "摘要"
    case .waiting: return "等 \(immediateWaiting + periodicWaiting)"
    case .retrying:
      guard let retryAt else { return "重试" }
      return "\(Int(max(0, retryAt.timeIntervalSince(now)).rounded(.up)))s"
    case .attention: return "新关注"
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
    case .summarizing: "CPA 正在摘要 \(summaries.count) 个群"
    case .waiting: "\(immediateWaiting + periodicWaiting) 个摘要任务排队"
    case .retrying: "摘要或判断失败，等待重试"
    case .attention: "有新的关注内容"
    }
  }
}

private struct NotchBar: View {
  let controller: NotchController
  @Environment(AppStore.self) var store
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  var body: some View {
    let count = store.pendingFocusCount
    let activity = store.activity
    Button {
      controller.toggle()
    } label: {
      HStack(spacing: 0) {
        // 只有缓冲倒计时 / 重试倒数需要时钟；空闲时暂停，避免每 0.1 秒重算整条工具栏。
        TimelineView(.animation(minimumInterval: 0.1, paused: !activity.needsClock || controller.expanded)) { context in
          HStack(spacing: 5) {
            ActivityGlyph(phase: activity.phase, deadline: activity.buffer.deadline,
                          total: store.preferences.bufferInterval, animate: !controller.expanded)
            // 展开后标题区已显示完整状态，收起态才显示标签。
            if !controller.expanded, let label = activity.compactLabel(now: activity.needsClock ? context.date : Date()) {
              Text(label).font(.system(size: 11, weight: .semibold, design: .rounded)).monospacedDigit()
                .foregroundStyle(IslandColor.of(activity.phase)).lineLimit(1).fixedSize()
                .transition(.opacity.combined(with: .move(edge: .leading)))
            }
          }
        }
        .frame(maxWidth: .infinity)
        Color.clear.frame(width: controller.metrics.hasNotch ? controller.notchWidth : 50)
        HStack(spacing: 4) {
          if controller.pinned { Image(systemName: "pin.fill").font(.system(size: 9)) }
          Text(count == 0 ? "·" : "\(count)")
            .font(.system(size: 11, weight: .semibold, design: .rounded)).monospacedDigit()
            .contentTransition(.numericText(value: Double(count)))
            .scaleEffect(activity.phase == .attention && !reduceMotion ? 1.25 : 1)
        }.foregroundStyle(activity.phase == .attention ? .white : IslandColor.count).frame(maxWidth: .infinity)
      }.padding(.horizontal, 8).frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .animation(reduceMotion ? nil : .spring(duration: 0.4, bounce: 0.45), value: count)
        .animation(reduceMotion ? nil : .spring(duration: 0.35, bounce: 0.3), value: activity.phase)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("群岛，\(activity.accessibilityText)，\(count) 条待关注内容。点击固定或收起")
    }.buttonStyle(.plain)
  }
}

/// 展开面板顶部的处理流水线：缓冲 → Jev → CPA。各阶段并行时分别点亮。
private struct NotchPipeline: View {
  let activity: IslandActivity
  let interval: Double
  let usesJev: Bool
  let animate: Bool
  var body: some View {
    TimelineView(.animation(minimumInterval: 0.1, paused: !activity.needsClock || !animate)) { context in
      let now = activity.needsClock ? context.date : Date()
      VStack(alignment: .leading, spacing: 7) {
        HStack(spacing: 0) {
          step("缓冲", bufferDetail(now), phase: activity.buffer.isEmpty ? nil : .buffering)
          link(on: activity.judging)
          step(usesJev ? "Jev 判断" : "本地识别", jevDetail, phase: activity.judging ? .judging : (activity.judgeBatches > 0 && usesJev ? .waiting : nil))
          link(on: activity.summaries.contains(where: \.loading))
          step("CPA 摘要", cpaDetail(now), phase: cpaPhase)
        }.frame(height: 30)
        GeometryReader { proxy in
          let fraction = activity.buffer.deadline.map { max(0, min(1, $0.timeIntervalSince(now) / max(0.1, interval))) } ?? 0
          ZStack(alignment: .leading) {
            Capsule().fill(Color.white.opacity(0.07))
            Capsule().fill(IslandColor.amber).frame(width: proxy.size.width * fraction)
          }
        }.frame(height: 2).opacity(activity.buffer.isEmpty ? 0 : 1)
        HStack(spacing: 6) {
          ForEach(chips, id: \.0) { chip in
            HStack(spacing: 5) {
              Circle().fill(chip.2).frame(width: 5, height: 5)
              Text(chip.1).lineLimit(1)
            }.font(.system(size: 10.5)).foregroundStyle(.white.opacity(0.78))
              .padding(.horizontal, 7).padding(.vertical, 2)
              .background(Color.white.opacity(0.06), in: Capsule())
          }
          Spacer(minLength: 0)
        }.frame(height: 18).clipped()
      }
      .padding(.horizontal, 12).padding(.vertical, 9)
      .background(Color(white: 0.07), in: RoundedRectangle(cornerRadius: 12))
      .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.white.opacity(0.08)))
    }
    .accessibilityElement(children: .combine)
  }
  private var cpaPhase: IslandPhase? {
    if !activity.summaries.isEmpty { return activity.summaries.contains(where: { !$0.loading }) ? .summarizing : .loading }
    if activity.retryAt != nil { return .retrying }
    if activity.immediateWaiting + activity.periodicWaiting > 0 { return .waiting }
    return nil
  }
  private func bufferDetail(_ now: Date) -> String {
    guard let deadline = activity.buffer.deadline else { return "空" }
    let left = max(0, deadline.timeIntervalSince(now))
    return activity.buffer.count >= activity.buffer.capacity ? "\(activity.buffer.count) 条 · 容量已满"
      : "\(activity.buffer.count) 条 · \(String(format: "%.1f", left))s 后提交"
  }
  private var jevDetail: String {
    if activity.judging { return activity.judgeBatches > 1 ? "判断中 · 余 \(activity.judgeBatches - 1) 批" : "判断中" }
    if activity.judgeBatches > 0 { return usesJev ? "待判 \(activity.judgeBatches) 批" : "处理中" }
    return usesJev ? "空闲" : "直接命中即提交"
  }
  private func cpaDetail(_ now: Date) -> String {
    if let first = activity.summaries.first {
      if activity.summaries.count > 1 { return "\(activity.summaries.count)/\(activity.concurrency) 个群" }
      return first.loading ? "读取全部未读…" : "\(first.messages) 条 · 第 \(max(1, first.requests)) 次请求"
    }
    if let retryAt = activity.retryAt { return "\(Int(max(0, retryAt.timeIntervalSince(now)).rounded(.up)))s 后重试" }
    let waiting = activity.immediateWaiting + activity.periodicWaiting
    return waiting > 0 ? "等待 \(waiting)" : "空闲"
  }
  private var chips: [(String, String, Color)] {
    var result: [(String, String, Color)] = []
    for item in activity.summaries.prefix(2) {
      result.append(("s" + item.group, "\(item.groupName) · \(item.loading ? "读取未读" : "\(item.messages) 条未读")", IslandColor.cyan))
    }
    if let name = activity.judgingGroupName { result.append(("j", "\(name) · Jev", IslandColor.violet)) }
    for group in activity.buffer.groups.prefix(2) {
      result.append(("b" + group.group, "\(AppStore.shared.groupName(group.group)) · \(group.count) 条", IslandColor.amber))
    }
    if result.isEmpty, activity.immediateWaiting + activity.periodicWaiting > 0 {
      result.append(("w", "即时等待 \(activity.immediateWaiting) · 定时等待 \(activity.periodicWaiting)", IslandColor.grey))
    }
    if result.isEmpty, activity.retryAt != nil { result.append(("r", "失败已保留，进度未推进", IslandColor.orange)) }
    return Array(result.prefix(3))
  }
  private func link(on: Bool) -> some View {
    Capsule().fill(on ? Color.white.opacity(0.45) : Color.white.opacity(0.12)).frame(width: 16, height: 1).padding(.horizontal, 6)
  }
  private func step(_ title: String, _ detail: String, phase: IslandPhase?) -> some View {
    let lit = phase != nil
    return HStack(spacing: 7) {
      ActivityGlyph(phase: phase ?? .paused, deadline: activity.buffer.deadline, total: interval, animate: animate && lit)
        .opacity(lit ? 1 : 0.45)
      VStack(alignment: .leading, spacing: 1) {
        Text(title).font(.system(size: 11.5, weight: .semibold))
          .foregroundStyle(lit ? IslandColor.of(phase!) : Color.white.opacity(0.4))
        Text(detail).font(.system(size: 10)).monospacedDigit().lineLimit(1)
          .foregroundStyle(lit ? Color.white.opacity(0.72) : Color.white.opacity(0.32))
      }
    }.frame(maxWidth: .infinity, alignment: .leading)
  }
}

/// 刘海展开内容：每行一个群，显示群名与最新待关注摘要；点击行在主窗口打开该群。
private struct NotchExpandedContent: View {
  let controller: NotchController
  @Environment(AppStore.self) var store
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  var body: some View {
    let threads = store.pendingAttention.threads
    let activity = store.activity
    VStack(spacing: 0) {
      HStack(spacing: 10) {
        Text("需要关注").font(.system(size: 13, weight: .semibold))
        Text("\(store.pendingFocusCount)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
          .contentTransition(.numericText(value: Double(store.pendingFocusCount)))
        Spacer()
        Button("一键已阅", systemImage: "checkmark.circle") {
          store.readFocusEntries(store.pendingAttention.entries)
        }.buttonStyle(.borderless).font(.caption).disabled(threads.isEmpty)
          .help("将当前账号所有待关注内容标记已阅；不改变微信未读")
        Button { controller.togglePin() } label: {
          Image(systemName: controller.pinned ? "pin.fill" : "pin")
        }.buttonStyle(.plain).foregroundStyle(.secondary)
          .help(controller.pinned ? "取消固定" : "固定刘海")
          .accessibilityLabel(controller.pinned ? "取消固定" : "固定刘海")
        Button { controller.collapse() } label: { Image(systemName: "chevron.up") }
          .buttonStyle(.plain).foregroundStyle(.secondary).help("收起刘海").accessibilityLabel("收起刘海")
      }.padding(.horizontal, 16).frame(height: 44)
      if activity.pipelineVisible {
        NotchPipeline(activity: activity, interval: store.preferences.bufferInterval,
                      usesJev: store.preferences.usesJev, animate: controller.contentVisible)
          .padding(.horizontal, 12).padding(.bottom, 8)
          .frame(height: NotchController.pipelineHeight, alignment: .top)
          .transition(.opacity.combined(with: .move(edge: .top)))
      }
      if threads.isEmpty {
        VStack(spacing: 8) {
          Image(systemName: "checkmark.bubble").font(.title2).foregroundStyle(.secondary)
          Text("暂无待关注内容").font(.callout)
          Text("与你相关的群聊摘要会出现在这里").font(.caption).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
      } else {
        let updating = Set(activity.summaries.map(\.group))
        ScrollView {
          LazyVStack(spacing: 0) {
            ForEach(Array(threads.enumerated()), id: \.element.id) { index, thread in
              NotchThreadRow(thread: thread, updating: updating.contains(thread.id), separated: index > 0) {
                store.attentionGroupID = thread.id
                store.page = .attention
                AppDelegate.shared?.showMain()
                controller.collapse()
              }
              .transition(.opacity.combined(with: .move(edge: .top)))
            }
          }.padding(.horizontal, 8).padding(.bottom, 4)
            // 直接在测量视图内回报高度：preference 在这个宿主中不能从 ScrollView 内容向外传递。
            .background(GeometryReader { proxy in
              Color.clear
                .onAppear { controller.listMeasured(proxy.size.height) }
                .onChange(of: proxy.size.height) { _, height in controller.listMeasured(height) }
            })
        }.scrollIndicators(.automatic)
      }
      HStack(spacing: 6) {
        Text(footer(activity)).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
        Spacer()
        Button("打开主窗口 ↗") {
          store.page = .attention
          AppDelegate.shared?.showMain()
          controller.collapse()
        }.buttonStyle(.borderless).font(.caption)
      }.padding(.horizontal, 16).frame(height: 38)
        .overlay(alignment: .top) { Rectangle().fill(Color.white.opacity(0.06)).frame(height: 1) }
    }
    .animation(reduceMotion ? nil : .spring(duration: 0.35, bounce: 0.2), value: activity.pipelineVisible)
    .animation(reduceMotion ? nil : .spring(duration: 0.4, bounce: 0.25), value: threads.map(\.id))
    // 收起时内容仍在排版（以便测量高度），但不暴露给辅助功能、不接收点击。
    .accessibilityHidden(!controller.contentVisible)
    .allowsHitTesting(controller.contentVisible)
  }
  private func footer(_ activity: IslandActivity) -> String {
    switch activity.phase {
    case .paused: return "已暂停监听"
    case .attention: return "已生成新的关注内容"
    case .idle:
      if let last = store.lastAnalysis { return "全部处理完毕 · 上次摘要 \(last.formatted(.dateTime.hour().minute()))" }
      return "全部处理完毕"
    default: return store.queueDescription
    }
  }
}

/// 群头像：按群名稳定取色，区分相邻群；与主窗口头像共用首字规则。
private struct NotchAvatar: View {
  let name: String
  var body: some View {
    let hue = Double(name.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) % 360 }) / 360
    Text(String(name.prefix(1))).font(.system(size: 13, weight: .semibold))
      .foregroundStyle(Color(hue: hue, saturation: 0.45, brightness: 1))
      .frame(width: 30, height: 30)
      .background(Color(hue: hue, saturation: 0.5, brightness: 0.5).opacity(0.32), in: RoundedRectangle(cornerRadius: 9))
      .accessibilityHidden(true)
  }
}

/// 一行一个群，完整显示本群每条待关注摘要；悬停时右上角时间换成「本群已阅」，不再遮挡内容。
private struct NotchThreadRow: View {
  @Environment(AppStore.self) var store
  let thread: AttentionThread
  let updating: Bool
  let separated: Bool
  let open: () -> Void
  @State private var hovering = false
  var body: some View {
    let latest = thread.entries[0]
    let multi = thread.entries.count > 1
    HStack(alignment: .top, spacing: 10) {
      NotchAvatar(name: latest.groupName)
      VStack(alignment: .leading, spacing: 5) {
        HStack(spacing: 6) {
          Text(latest.groupName).font(.system(size: 12.5, weight: .semibold)).lineLimit(1)
          if thread.pendingCount > 1 {
            Text("\(thread.pendingCount)").font(.system(size: 10, weight: .medium).monospacedDigit())
              .foregroundStyle(IslandColor.count).padding(.horizontal, 6).padding(.vertical, 1)
              .background(Color.indigo.opacity(0.25), in: Capsule())
          }
          if updating {
            HStack(spacing: 4) {
              ActivityGlyph(phase: .summarizing, size: 10)
              Text("正在更新")
            }.font(.system(size: 10)).foregroundStyle(IslandColor.cyan)
              .transition(.opacity)
          }
          Spacer(minLength: 4)
          ZStack(alignment: .trailing) {
            Text(latest.date, format: .dateTime.hour().minute()).font(.system(size: 10.5))
              .foregroundStyle(.secondary).monospacedDigit().opacity(hovering ? 0 : 1)
            Button { store.readFocusEntries(thread.entries) } label: {
              Text("本群已阅").font(.system(size: 10.5))
                .padding(.horizontal, 7).padding(.vertical, 2)
                .background(Color.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 6))
            }.buttonStyle(.plain).foregroundStyle(.white.opacity(0.85))
              .opacity(hovering ? 1 : 0).allowsHitTesting(hovering)
              .help("本群已阅，不改变微信未读").accessibilityLabel("本群已阅")
          }.frame(height: 18)
        }
        VStack(alignment: .leading, spacing: 7) {
          ForEach(Array(thread.entries.enumerated()), id: \.element.id) { index, entry in
            HStack(alignment: .top, spacing: 0) {
              if multi {
                Rectangle().fill(index == 0 ? Color.indigo.opacity(0.7) : Color.white.opacity(0.1))
                  .frame(width: 2).padding(.trailing, 8)
              }
              VStack(alignment: .leading, spacing: 5) {
                (multi ? Text(entry.date, format: .dateTime.hour().minute()).font(.system(size: 10)).foregroundColor(.secondary)
                  + Text("  ") : Text(""))
                  + Text(entry.preview).font(.system(size: 11.5)).foregroundColor(.white.opacity(0.84))
                let tags = thread.tags(for: entry)
                if !tags.isEmpty { AttentionTags(tags: tags, dark: true) }
              }
            }
            .lineSpacing(3).multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
          }
        }
      }
    }
    .padding(.horizontal, 8).padding(.vertical, 10)
    .contentShape(Rectangle())
    .background(Color.white.opacity(hovering ? 0.06 : 0), in: RoundedRectangle(cornerRadius: 12))
    .overlay(alignment: .top) {
      if separated && !hovering {
        Rectangle().fill(Color.white.opacity(0.06)).frame(height: 1).padding(.leading, 48).padding(.trailing, 8)
      }
    }
    .onTapGesture(perform: open)
    .onHover { hovering = $0 }
    .animation(.easeOut(duration: 0.12), value: hovering)
    .accessibilityElement(children: .contain)
    .accessibilityAddTraits(.isButton)
    .accessibilityLabel("\(latest.groupName)，\(thread.pendingCount) 条待关注\(updating ? "，正在更新" : "")")
    .accessibilityHint("在主窗口打开本群")
    .accessibilityAction { open() }
  }
}
