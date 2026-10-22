import Foundation
import AppKit
import QuartzCore
import os

/// 性能探针：用 os_signpost 标记页面切换与刘海动画，可在 Instruments「Points of Interest」中查看。
/// 页面切换耗时从选中页面起算，到下一次 Core Animation 提交完成（新页面首帧已排版渲染）为止。
/// 只记录页面名称和耗时，不涉及聊天内容。
enum PerfProbe {
  static let signposter = OSSignposter(subsystem: "cn.kiliter.qundao", category: .pointsOfInterest)
  private static let logger = Logger(subsystem: "cn.kiliter.qundao", category: "perf")

  @MainActor static func pageSwitch(to name: String) {
    let id = signposter.makeSignpostID()
    let state = signposter.beginInterval("页面切换", id: id, "\(name, privacy: .public)")
    let start = CACurrentMediaTime()
    // 等当前事件处理完、SwiftUI 提交新页面后再结束区间。
    DispatchQueue.main.async {
      CATransaction.begin()
      CATransaction.setCompletionBlock {
        signposter.endInterval("页面切换", state)
        logger.notice("页面切换 \(name, privacy: .public) \(Int((CACurrentMediaTime() - start) * 1000)) ms")
      }
      CATransaction.commit()
    }
  }

  @MainActor static func notchAnimation(_ name: String, duration: Double) {
    let state = signposter.beginInterval("刘海动画", id: signposter.makeSignpostID(), "\(name, privacy: .public)")
    let monitor = FrameMonitor.start()
    DispatchQueue.main.asyncAfter(deadline: .now() + duration) {
      signposter.endInterval("刘海动画", state)
      if let report = monitor?.stop() {
        logger.notice("刘海动画 \(name, privacy: .public) \(report, privacy: .public)")
      }
    }
  }
}

/// 基于屏幕 CADisplayLink 统计主线程能否按刷新率处理每一帧；只在基准模式下启用。
@MainActor final class FrameMonitor: NSObject {
  private var link: CADisplayLink?
  private var last: CFTimeInterval = 0
  private var intervals: [CFTimeInterval] = []
  static func start() -> FrameMonitor? {
    guard PerfBenchmark.enabled, let screen = NSScreen.main else { return nil }
    let monitor = FrameMonitor()
    let link = screen.displayLink(target: monitor, selector: #selector(tick(_:)))
    link.add(to: .main, forMode: .common)
    monitor.link = link
    return monitor
  }
  @objc private func tick(_ link: CADisplayLink) {
    if last > 0 { intervals.append(link.timestamp - last) }
    last = link.timestamp
  }
  func stop() -> String {
    link?.invalidate(); link = nil
    guard !intervals.isEmpty else { return "无帧" }
    let expected = intervals.sorted()[intervals.count / 2]
    let dropped = intervals.filter { $0 > expected * 1.5 }.count
    let worst = (intervals.max() ?? 0) * 1000
    return String(format: "帧 %d，基准间隔 %.1f ms，超时帧 %d，最长 %.1f ms", intervals.count, expected * 1000, dropped, worst)
  }
}

/// 内置基准：仅在环境变量 QUNDAO_PERF_BENCH=1 启动时运行。
/// 按固定节奏切换主窗口页面并展开 / 收起刘海，配合 PerfProbe 日志与 Instruments 测量；
/// 只改变界面导航，不读写聊天数据、不改变已阅或白名单。
@MainActor enum PerfBenchmark {
  /// 1：页面切换 + 刘海；notch：只测刘海。
  static var mode: String? { ProcessInfo.processInfo.environment["QUNDAO_PERF_BENCH"] }
  static var enabled: Bool { mode != nil }
  static func run(store: AppStore) {
    guard enabled else { return }
    Task { @MainActor in
      try? await Task.sleep(nanoseconds: 4_000_000_000)
      let pages: [Page] = [.summary, .groups, .rules, .appearance, .connection, .logs, .attention]
      if mode == "resize" { await resize(); return }
      if mode == "scroll" { await scroll(); return }
      if mode == "live" { observeLiveScroll(); return }
      if mode == "trackpad" { await trackpad(); return }
      for round in 0..<(mode == "notch" ? 0 : 3) {
        for page in pages {
          store.page = page
          try? await Task.sleep(nanoseconds: 700_000_000)
        }
        Logger(subsystem: "cn.kiliter.qundao", category: "perf").notice("基准第 \(round + 1) 轮页面切换完成")
      }
      for _ in 0..<5 {
        NotchController.shared?.expand(pin: true)
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        NotchController.shared?.collapse()
        try? await Task.sleep(nanoseconds: 1_000_000_000)
      }
      Logger(subsystem: "cn.kiliter.qundao", category: "perf").notice("基准结束")
    }
  }
  /// trackpad：向本进程投递带手势阶段与惯性阶段的连续滚轮事件，走与触控板相同的事件分发路径。
  private static func trackpad() async {
    let logger = Logger(subsystem: "cn.kiliter.qundao", category: "perf")
    guard let window = AppDelegate.shared?.mainWindow else { return }
    window.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
    for page in [Page.rules, .appearance, .connection, .rules] {
      AppStore.shared.page = page
      try? await Task.sleep(nanoseconds: 1_200_000_000)
      guard let scroll = largestVisibleScrollView(in: window.contentView) else { continue }
      let rect = window.convertToScreen(scroll.convert(scroll.bounds, to: nil))
      let primary = NSScreen.screens.first?.frame.height ?? 0
      let location = CGPoint(x: rect.midX, y: primary - rect.midY)
      let monitor = FrameMonitor.start()
      for direction in [-1.0, 1.0] {
        func post(_ dy: Double, phase: Int64, momentum: Int64) {
          guard let e = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: Int32(dy), wheel2: 0, wheel3: 0) else { return }
          e.location = location
          e.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
          e.setIntegerValueField(.scrollWheelEventScrollPhase, value: phase)
          e.setIntegerValueField(.scrollWheelEventMomentumPhase, value: momentum)
          e.setDoubleValueField(.scrollWheelEventPointDeltaAxis1, value: dy)
          e.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1, value: dy)
          e.postToPid(getpid())
        }
        post(0, phase: 1, momentum: 0)
        for _ in 0..<30 { post(direction * 9, phase: 2, momentum: 0); try? await Task.sleep(nanoseconds: 8_300_000) }
        post(0, phase: 4, momentum: 0)
        var v = direction * 14
        post(v, phase: 0, momentum: 1)
        for _ in 0..<70 { v *= 0.95; post(v.rounded(), phase: 0, momentum: 2); try? await Task.sleep(nanoseconds: 8_300_000) }
        post(0, phase: 0, momentum: 3)
        try? await Task.sleep(nanoseconds: 300_000_000)
      }
      logger.notice("触控板 \(page.rawValue, privacy: .public) \(monitor?.stop() ?? "无", privacy: .public)")
    }
    logger.notice("基准结束")
  }
  /// live：不主动操作界面，统计用户真实滚动（含惯性）期间的帧间隔。
  private static func observeLiveScroll() {
    let logger = Logger(subsystem: "cn.kiliter.qundao", category: "perf")
    var monitor: FrameMonitor?
    let center = NotificationCenter.default
    center.addObserver(forName: NSScrollView.willStartLiveScrollNotification, object: nil, queue: .main) { _ in
      MainActor.assumeIsolated { if monitor == nil { monitor = FrameMonitor.start() } }
    }
    center.addObserver(forName: NSScrollView.didEndLiveScrollNotification, object: nil, queue: .main) { note in
      MainActor.assumeIsolated {
        let name = (note.object as? NSScrollView).map { String(describing: type(of: $0.documentView ?? $0)) } ?? "?"
        if let report = monitor?.stop() { logger.notice("真实滚动 \(AppStore.shared.page.rawValue, privacy: .public) \(name, privacy: .public) \(report, privacy: .public)") }
        monitor = nil
      }
    }
    logger.notice("真实滚动观察已开启")
  }
  /// 在各偏好设置页逐帧上下滚动可见的滚动视图，统计主线程帧间隔。
  private static func scroll() async {
    let logger = Logger(subsystem: "cn.kiliter.qundao", category: "perf")
    guard let window = AppDelegate.shared?.mainWindow else { logger.notice("滚动：未找到主窗口"); return }
    for page in [Page.rules, .appearance, .connection] {
      AppStore.shared.page = page
      try? await Task.sleep(nanoseconds: 1_000_000_000)
      guard let scroll = largestVisibleScrollView(in: window.contentView) else { logger.notice("滚动：\(page.rawValue, privacy: .public) 无滚动视图"); continue }
      let clip = scroll.contentView
      let maxY = max(0, (scroll.documentView?.frame.height ?? 0) - clip.bounds.height)
      clip.scroll(to: .zero); scroll.reflectScrolledClipView(clip)
      let monitor = FrameMonitor.start()
      // 模拟触控板滚轮：逐帧向滚动视图投递像素级滚轮事件，先向下再向上。
      let point = scroll.convert(NSPoint(x: scroll.bounds.midX, y: scroll.bounds.midY), to: nil)
      for step in 0..<180 {
        let dy: Int32 = step < 90 ? -6 : 6
        if let cg = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: dy, wheel2: 0, wheel3: 0),
           let event = NSEvent(cgEvent: cg) {
          cg.location = window.convertPoint(toScreen: point)
          _ = event
          if let located = NSEvent(cgEvent: cg) { scroll.scrollWheel(with: located) }
        }
        try? await Task.sleep(nanoseconds: 8_000_000)
      }
      logger.notice("滚动 \(page.rawValue, privacy: .public) 可滚动 \(Int(maxY)) pt \(monitor?.stop() ?? "无", privacy: .public)")
    }
    logger.notice("基准结束")
  }
  private static func largestVisibleScrollView(in view: NSView?) -> NSScrollView? {
    guard let view, !view.isHiddenOrHasHiddenAncestor else { return nil }
    var best = view as? NSScrollView
    for sub in view.subviews {
      if let found = largestVisibleScrollView(in: sub),
         found.frame.width * found.frame.height > (best.map { $0.frame.width * $0.frame.height } ?? 0) { best = found }
    }
    return best
  }
  /// 先访问全部页面使其常驻，再在当前页逐帧改变窗口尺寸，统计主线程帧间隔。
  private static func resize() async {
    let logger = Logger(subsystem: "cn.kiliter.qundao", category: "perf")
    guard let window = AppDelegate.shared?.mainWindow else { logger.notice("调整窗口：未找到主窗口"); return }
    for page in Page.allCases { AppStore.shared.page = page; try? await Task.sleep(nanoseconds: 400_000_000) }
    for page in [Page.attention, .summary, .groups] {
      AppStore.shared.page = page
      try? await Task.sleep(nanoseconds: 800_000_000)
      let origin = window.frame
      let monitor = FrameMonitor.start()
      for step in 0..<120 {
        let delta = CGFloat(sin(Double(step) / 120 * .pi * 2)) * 160
        window.setFrame(NSRect(x: origin.minX, y: origin.minY, width: origin.width + delta, height: origin.height), display: true)
        try? await Task.sleep(nanoseconds: 8_000_000)
      }
      window.setFrame(origin, display: true)
      logger.notice("调整窗口 \(page.rawValue, privacy: .public) \(monitor?.stop() ?? "无", privacy: .public)")
    }
    logger.notice("基准结束")
  }
}
