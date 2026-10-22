import AppKit
import ServiceManagement
import SwiftUI

struct StartupSettings: View {
  @Environment(AppStore.self) private var store
  @Environment(\.pageActive) private var pageActive
  @State private var loginItem = LoginItemController()
  @State private var dockError: String?

  var body: some View {
    P5SectionTitle("启动与 Dock")
    Toggle("开机自启", isOn: Binding(get: { loginItem.requested }, set: { enabled in
      Task { await loginItem.setEnabled(enabled) }
    })).disabled(loginItem.changing)
    Text("登录 Mac 时自动打开群岛。").font(.caption).foregroundStyle(.secondary)
    if loginItem.needsApproval {
      Text("尚未生效：请在系统设置的登录项中允许群岛。")
        .font(.caption).foregroundStyle(P5.red)
      Button("打开系统登录项设置") { SMAppService.openSystemSettingsLoginItems() }
    }
    if let error = loginItem.error {
      Text(error).font(.caption).foregroundStyle(P5.red).textSelection(.enabled)
    }
    Toggle("隐藏 Dock 图标", isOn: Binding(get: { store.preferences.hidesDockIcon }, set: { hidden in
      dockError = AppDelegate.shared?.setDockIconHidden(hidden) == true
        ? nil : "Dock 显示设置未能应用，请重试。"
    }))
    Text("立即生效并记住选择；隐藏后仍可通过菜单栏图标或刘海打开主窗口。")
      .font(.caption).foregroundStyle(.secondary)
    if let dockError { Text(dockError).font(.caption).foregroundStyle(P5.red) }
    Toggle("下次打开应用时自动恢复监听", isOn: Binding(
      get: { store.preferences.autoStart }, set: { value in store.update { $0.autoStart = value } }))
    Text("恢复监听会按已选账号和规则工作，不修改微信的已读状态。")
      .font(.caption).foregroundStyle(.secondary)
    // 独立页面宿主会被缓存，重新选中或从系统设置返回时都要读取系统最新状态。
      .onAppear { loginItem.refresh() }
      .onChange(of: pageActive) { _, active in if active { loginItem.refresh() } }
      .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
        loginItem.refresh()
      }
  }
}
