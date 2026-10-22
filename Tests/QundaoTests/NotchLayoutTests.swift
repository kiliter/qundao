import AppKit
import SwiftUI
import XCTest
@testable import Qundao

final class NotchLayoutTests: XCTestCase {
  @MainActor
  func testCameraGapStaysCenteredForScreenAndWidthSettings() async {
    for (screen, camera, hasNotch) in [(1512.0, 185.0, true), (1728, 220, true), (1920, 50, false)] {
      for active in [false, true] {
        for requested in [nil, 0, 500, 5000] as [Double?] {
          let layout = NotchBarLayout(centerWidth: camera, screenWidth: screen, hasNotch: hasNotch,
                                      preferredCompactWidth: requested, preferredExpandedWidth: 360,
                                      active: active, count: 999)
          for expanded in [false, true] {
            let width = layout.barWidth(expanded: expanded)
            let wing = layout.wingWidth(expanded: expanded)
            XCTAssertEqual(wing + camera / 2, width / 2, accuracy: 0.001)
            XCTAssertLessThanOrEqual(width, screen - 24)
            if expanded { XCTAssertLessThanOrEqual(width, layout.expandedWidth) }
          }
        }
      }
    }
  }

  @MainActor
  func testSliderMinimumMatchesIdleWidthAndExpandedBarDoesNotGrowWithActivity() async {
    for count in [0, 10, 999, 9999] {
      let idle = makeLayout(active: false, count: count, compact: 0)
      XCTAssertEqual(idle.minimumCompactWidth, idle.compactWidth)
      let active = makeLayout(active: true, count: count, compact: 0)
      XCTAssertEqual(idle.barWidth(expanded: true), active.barWidth(expanded: true))
      XCTAssertGreaterThanOrEqual(active.wingWidth(expanded: false), 108)
    }
    let narrow = makeLayout(active: false, count: 999, compact: 0)
    let wider = makeLayout(active: false, count: 999, compact: narrow.minimumCompactWidth + 2)
    XCTAssertEqual(wider.compactWidth - narrow.compactWidth, 2)
  }

  /// 直接渲染生产展示组件；不初始化 AppStore，不读取用户配置、缓存或网络。
  @MainActor
  func testRenderedBarKeepsCameraClearAndCountsVisible() async throws {
    let output = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("qundao-notch-layout", isDirectory: true)
    try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
    let cases: [(String, IslandPhase, Int, Bool)] = [
      ("空闲三位计数", .idle, 999, false),
      ("重试三位倒计时", .retrying, 12, false),
      ("重试六位倒计时", .retrying, 9999, false),
      ("展开固定三位计数", .retrying, 999, true),
      ("展开固定四位计数", .idle, 9999, true),
      ("新关注四位计数", .attention, 9999, false),
    ]
    for (name, phase, count, expanded) in cases {
      var activity = IslandActivity()
      activity.phase = phase
      activity.retryAt = Date().addingTimeInterval(name.contains("六位") ? 999999 : 269)
      let layout = makeLayout(active: phase.isActive, count: count, compact: 0)
      let width = layout.barWidth(expanded: expanded)
      let view = NotchBarContent(activity: activity, count: count, expanded: expanded,
                                 pinned: expanded, layout: layout)
        .transaction { $0.animation = nil; $0.disablesAnimations = true }
        .frame(width: width, height: 32)
        .background(Color.black)
      let bitmap = try render(view, size: CGSize(width: width, height: 32))
      try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: output.appendingPathComponent("\(name).png"))
      let scale = Double(bitmap.pixelsWide) / width
      let centerStart = Int(ceil(layout.wingWidth(expanded: expanded) * scale))
      let centerEnd = Int(floor((layout.wingWidth(expanded: expanded) + layout.centerWidth) * scale))
      XCTAssertEqual(ink(bitmap, from: centerStart, to: centerEnd), 0, "\(name)：内容进入摄像头区域")
      XCTAssertGreaterThan(ink(bitmap, from: 0, to: centerStart), 20, "\(name)：左翼未绘制")
      if !expanded, let label = activity.compactLabel(now: Date()) {
        let labelReference = try render(Text(label).font(P5.heavy(11)).monospacedDigit().foregroundStyle(.white)
          .frame(width: 130, height: 32).background(Color.black), size: CGSize(width: 130, height: 32))
        XCTAssertGreaterThanOrEqual(Double(whiteInk(bitmap, from: 0, to: centerStart)),
          Double(whiteInk(labelReference, from: 0, to: labelReference.pixelsWide)) * 0.9,
          "\(name)：状态标签未完整绘制")
      }
      let reference = try render(Text(String(count)).font(P5.numeral(13)).foregroundStyle(.white)
        .frame(width: 130, height: 32).background(Color.black), size: CGSize(width: 130, height: 32))
      // 裁切或换行会显著减少数字像素；固定图标为红色，不计入白色像素。
      let visibleCount = phase == .attention ? ink(bitmap, from: centerEnd, to: bitmap.pixelsWide)
        : whiteInk(bitmap, from: centerEnd, to: bitmap.pixelsWide)
      let referenceCount = whiteInk(reference, from: 0, to: reference.pixelsWide)
      XCTAssertGreaterThanOrEqual(Double(visibleCount), Double(referenceCount) * 0.9, "\(name)：计数不完整")
    }
    print("刘海合成渲染：\(output.path)")
  }

  @MainActor
  private func makeLayout(active: Bool, count: Int, compact: Double?) -> NotchBarLayout {
    NotchBarLayout(centerWidth: 185, screenWidth: 1512, hasNotch: true,
                   preferredCompactWidth: compact, preferredExpandedWidth: 360,
                   active: active, count: count)
  }

  @MainActor
  private func render<V: View>(_ view: V, size: CGSize) throws -> NSBitmapImageRep {
    let host = NSHostingView(rootView: view)
    host.sizingOptions = []
    host.safeAreaRegions = []
    host.frame = CGRect(origin: .zero, size: size)
    host.appearance = NSAppearance(named: .darkAqua)
    host.layoutSubtreeIfNeeded()
    let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
    host.cacheDisplay(in: host.bounds, to: bitmap)
    return bitmap
  }

  private func ink(_ bitmap: NSBitmapImageRep, from: Int, to: Int) -> Int {
    pixels(bitmap, from: from, to: to) { r, g, b in max(r, g, b) > 0.25 }
  }

  private func whiteInk(_ bitmap: NSBitmapImageRep, from: Int, to: Int) -> Int {
    pixels(bitmap, from: from, to: to) { r, g, b in min(r, g, b) > 0.6 }
  }

  private func pixels(_ bitmap: NSBitmapImageRep, from: Int, to: Int,
                      matches: (CGFloat, CGFloat, CGFloat) -> Bool) -> Int {
    var count = 0
    for y in 0..<bitmap.pixelsHigh {
      for x in max(0, from)..<min(to, bitmap.pixelsWide) {
        if let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB),
           color.alphaComponent > 0.5, matches(color.redComponent, color.greenComponent, color.blueComponent) {
          count += 1
        }
      }
    }
    return count
  }
}
