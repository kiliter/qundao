import SwiftUI

struct IslandDisplayControls: View {
  @Environment(AppStore.self) private var store
  @ObservedObject private var placeholders = MenuPlaceholders.shared
  private var controller: NotchController? { NotchController.shared }
  private var screens: [NotchScreen] { controller?.availableScreens ?? [] }
  private var preferredID: String? { store.preferences.notchDisplayID }
  private var disconnected: Bool {
    preferredID != nil && !screens.contains { $0.id == preferredID }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Picker("显示屏", selection: Binding<String?>(get: { preferredID }, set: { id in
        let name = screens.first { $0.id == id }?.name
        store.update { $0.notchDisplayID = id; $0.notchDisplayName = name }
      })) {
        Text("自动选择").tag(nil as String?)
        ForEach(screens) { screen in
          Text(screen.label).tag(Optional(screen.id))
        }
        if disconnected, let preferredID {
          Text("\(store.preferences.notchDisplayName ?? "所选显示屏")（未连接）").tag(Optional(preferredID))
        }
      }.pickerStyle(.menu).accessibilityIdentifier("notchDisplayPicker")
      if let current = controller?.currentScreen {
        Text(disconnected ? "所选屏幕未连接，暂时显示在\(current.name)；接回后自动恢复。"
             : "当前显示：\(current.name)")
          .font(.caption).foregroundStyle(.secondary)
      } else {
        Text("当前没有可用显示屏，连接后会自动恢复刘海。")
          .font(.caption).foregroundStyle(.secondary)
      }
      Text("自动选择优先使用带刘海的屏幕，否则使用主显示器。指定屏幕后即时生效，重启后保留。")
        .font(.caption).foregroundStyle(.secondary)
      if let controller {
        Toggle("摆放占位图标", isOn: Binding(get: { controller.arrangingPlaceholders },
          set: { controller.arrangingPlaceholders = $0 })).toggleStyle(.switch)
      }
      HStack {
        Text("占位图标宽度")
        Slider(value: Binding(get: { placeholders.width }, set: { placeholders.setCustomWidth($0) }),
               in: 24...max(680, placeholders.width), onEditingChanged: placeholders.editingChanged)
          .accessibilityLabel("占位图标宽度")
        Text("\(Int(placeholders.width)) pt").monospacedDigit()
        Button("跟随刘海") { placeholders.setCustomWidth(nil) }
          .disabled(placeholders.customWidth == nil)
      }
      Button("添加占位图标") {
        controller?.arrangingPlaceholders = true
        placeholders.add()
      }
      Text("拖动滑杆立即调整宽占位图标，点「跟随刘海」恢复等宽。添加时刘海自动下移。按住 ⌘ 拖动图标，摆好后关闭开关，刘海即恢复贴顶。点击占位图标可移除它。")
        .font(.caption).foregroundStyle(.secondary)
    }
  }
}
