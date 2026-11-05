import AppKit
import ColorSync

/// 一次屏幕配置快照；设置列表和刘海定位共用，窗口焦点变化不会改变选择。
struct NotchScreen: Identifiable, Equatable {
  let id: String
  let name: String
  let number: Int
  let isBuiltIn: Bool
  let isPrimary: Bool
  let metrics: NotchScreenMetrics

  var label: String {
    let traits = [isBuiltIn ? "内置" : nil, isPrimary ? "主显示器" : nil].compactMap { $0 }
    let suffix = traits.isEmpty ? "" : "（\(traits.joined(separator: "，"))）"
    return "\(number). \(name)\(suffix)"
  }

  /// 指定屏幕优先；断开时临时使用自动选择，调用方保留原偏好以便接回后恢复。
  static func resolve(preferredID: String?, screens: [NotchScreen]) -> NotchScreen? {
    if let preferredID, let selected = screens.first(where: { $0.id == preferredID }) { return selected }
    return screens.first(where: { $0.metrics.hasNotch })
      ?? screens.first(where: { $0.isPrimary }) ?? screens.first
  }

  @MainActor
  static func connected() -> [NotchScreen] {
    NSScreen.screens.enumerated().compactMap { index, screen in
      guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return nil }
      let displayID = number.uint32Value
      // 使用显示器 UUID，避免重启、排列调整后按数组下标选错屏幕。
      let id: String
      if let uuid = CGDisplayCreateUUIDFromDisplayID(displayID)?.takeRetainedValue() {
        id = CFUUIDCreateString(nil, uuid) as String
      } else {
        id = "display-\(displayID)"
      }
      var cameraWidth: CGFloat = 90
      if let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea {
        cameraWidth = max(160, right.minX - left.maxX)
      }
      return NotchScreen(id: id, name: screen.localizedName, number: index + 1,
        isBuiltIn: CGDisplayIsBuiltin(displayID) != 0, isPrimary: index == 0,
        metrics: NotchScreenMetrics(frame: screen.frame, visibleHeight: screen.visibleFrame.height,
          hasNotch: screen.safeAreaInsets.top > 0, notchWidth: cameraWidth,
          barHeight: max(32, screen.safeAreaInsets.top),
          menuBarHeight: max(NSStatusBar.system.thickness, screen.frame.maxY - screen.visibleFrame.maxY)))
    }
  }
}

struct NotchScreenMetrics: Equatable {
  var frame: CGRect
  var visibleHeight: CGFloat
  var hasNotch: Bool
  var notchWidth: CGFloat
  var barHeight: CGFloat
  var menuBarHeight: CGFloat = 0

  /// 无屏幕时仅用于宿主初始化，窗口保持隐藏，连接屏幕后立即替换。
  static let unavailable = NotchScreenMetrics(frame: CGRect(x: 0, y: 0, width: 800, height: 600),
    visibleHeight: 600, hasNotch: false, notchWidth: 90, barHeight: 32)

  func panelFrame(size: CGSize) -> CGRect {
    CGRect(x: frame.midX - size.width / 2, y: frame.maxY - size.height,
      width: size.width, height: size.height)
  }
}
