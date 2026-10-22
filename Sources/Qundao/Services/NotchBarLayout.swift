import AppKit

/// 工具条、窗口宿主与宽度设置共用的尺寸，摄像头区域始终位于两翼正中。
struct NotchBarLayout: Equatable {
  let centerWidth: CGFloat
  let minimumCompactWidth: CGFloat
  let idleWidth: CGFloat
  let compactWidth: CGFloat
  let expandedWidth: CGFloat

  init(centerWidth: CGFloat, screenWidth: CGFloat, hasNotch: Bool,
       preferredCompactWidth: Double?, preferredExpandedWidth: Double?,
       active: Bool, count: Int) {
    self.centerWidth = centerWidth
    // 字体与右侧计数一致，并预留斜体外伸、新关注放大和固定图标的位置。
    let text = count == 0 ? "—" : String(count)
    let font = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .heavy)
    let countWidth = (text as NSString).size(withAttributes: [.font: font]).width
    let idleWing = max(36, ceil(countWidth * 1.35) + 4 + 12 + 16)
    let limit = screenWidth - 24
    minimumCompactWidth = min(max(centerWidth + idleWing * 2, hasNotch ? 0 : 140), limit)
    idleWidth = min(max(minimumCompactWidth, preferredCompactWidth ?? minimumCompactWidth + 16), limit)
    compactWidth = min(max(idleWidth + (active ? 52 : 0), centerWidth + (active ? max(108, idleWing) : idleWing) * 2), limit)
    expandedWidth = min(max(360, preferredExpandedWidth ?? 440), limit)
  }

  /// 展开时没有阶段标签，使用空闲宽度且不能超出展开遮罩。
  func barWidth(expanded: Bool) -> CGFloat {
    expanded ? min(idleWidth, expandedWidth) : compactWidth
  }

  func wingWidth(expanded: Bool) -> CGFloat {
    max(0, (barWidth(expanded: expanded) - centerWidth) / 2)
  }
}
