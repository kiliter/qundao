import SwiftUI

struct IslandSizeControls: View {
  @Environment(AppStore.self) var store
  private var minimum: Double { Double(NotchController.shared?.minimumCompactWidth ?? 140) }
  private var compact: Double { store.preferences.notchCompactWidth ?? minimum + 16 }
  var body: some View {
    VStack(alignment: .leading, spacing: 18) {
      widthControl("收起宽度", value: Binding(get: { max(minimum, compact) }, set: { value in
        store.update { $0.notchCompactWidth = value }
      }), range: minimum...max(500, minimum + 80))
      widthControl("展开宽度", value: Binding(get: { store.preferences.notchExpandedWidth ?? 440 }, set: { value in
        store.update { $0.notchExpandedWidth = value }
      }), range: 360...680)
      HStack {
        Text("收起宽度会避开摄像头区域；调整即时生效。")
          .font(.caption).foregroundStyle(.secondary)
        Spacer()
        Button("恢复默认") { store.update { $0.notchCompactWidth = nil; $0.notchExpandedWidth = nil } }
          .buttonStyle(.borderless).font(.caption)
      }
    }
  }
  private func widthControl(_ title: String, value: Binding<Double>, range: ClosedRange<Double>) -> some View {
    HStack(spacing: 16) {
      Text(title).frame(width: 65, alignment: .leading)
      // 不用 step：macOS 会为每个步进画刻度，160 个刻度让页面切换明显卡顿。改为写入时取偶数。
      Slider(value: Binding(get: { value.wrappedValue }, set: { value.wrappedValue = ($0 / 2).rounded() * 2 }), in: range)
        .accessibilityLabel(title)
      Text("\(Int(value.wrappedValue)) pt").monospacedDigit().foregroundStyle(.secondary).frame(width: 55, alignment: .trailing)
    }
  }
}

/// 仅展示当前尺寸的缩略示意；真实刘海仍由 NotchController 布局。
private struct IslandPreviewCard: View {
  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      P5Ransom(text: "需要关注")
      Text("与你有关的内容，在这里汇集。")
        .font(.system(size: 10)).foregroundStyle(P5.ink)
        .padding(10).frame(maxWidth: .infinity, alignment: .leading).background(.white)
    }.padding(14).background(P5.ink)
  }
}

struct IslandMiniPreview: View {
  @Environment(AppStore.self) private var store
  var body: some View {
    VStack(spacing: 0) {
      HStack {
        P5Spark().fill(P5.red).frame(width: 14, height: 14)
        Spacer()
        Text("摄像头避让区").font(.system(size: 8)).foregroundStyle(.white.opacity(0.35))
        Spacer()
        Text(verbatim: "\(store.pendingFocusCount)").font(P5.numeral(12)).foregroundStyle(.white)
      }.padding(.horizontal, 14).frame(height: 28).background(P5.ink)
      IslandPreviewCard()
    }.frame(maxWidth: min(340, (store.preferences.notchExpandedWidth ?? 440) * 0.65))
      .clipShape(UnevenRoundedRectangle(bottomLeadingRadius: 18, bottomTrailingRadius: 18))
      .frame(maxWidth: .infinity).padding(.bottom, 12)
      .accessibilityElement(children: .ignore).accessibilityLabel("刘海布局缩略示意")
  }
}
