import SwiftUI

struct IslandSizeControls: View {
  @EnvironmentObject var store: AppStore
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
      Slider(value: value, in: range, step: 2).accessibilityLabel(title)
      Text("\(Int(value.wrappedValue)) pt").monospacedDigit().foregroundStyle(.secondary).frame(width: 55, alignment: .trailing)
    }
  }
}
