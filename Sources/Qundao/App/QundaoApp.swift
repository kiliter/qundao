import AppKit
import SwiftUI
import UserNotifications

@main struct QundaoApp: App {
  @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
  @StateObject private var store = AppStore.shared
  var body: some Scene {
    WindowGroup("群岛", id: "main") {
      ContentView().environmentObject(store).background(WindowReader()).onAppear {
        AppDelegate.shared?.captureWindow()
      }
    }.defaultSize(width: 1100, height: 760).commands {
      CommandGroup(replacing: .newItem) {}
      CommandGroup(after: .appInfo) {
        Button("打开主窗口") { delegate.showMain() }.keyboardShortcut("o")
        Button("显示刘海") { NotchController.shared?.expand(pin: true) }.keyboardShortcut(
          "i", modifiers: [.command, .shift])
      }
    }
    Settings { ContentView().environmentObject(store) }
    MenuBarExtra {
      Button("打开主窗口") { delegate.showMain() }
      Button("查看需要关注") { NotchController.shared?.expand(pin: true) }
      Divider()
      Button(store.running ? "暂停监听" : "开始监听") { store.running ? store.stop() : store.start() }
      Button(store.isQuiet ? "关闭免打扰" : "免打扰 1 小时") { store.toggleQuiet() }
      Button("生成未读摘要") { store.requestAllAnalysis() }.disabled(!store.running || !store.preferences.aiEnabled)
      Divider()
      Button("关键词与规则") {
        store.page = .rules
        delegate.showMain()
      }
      Button("运行日志") {
        store.page = .logs
        delegate.showMain()
      }
      Divider()
      Button("退出群岛") { NSApp.terminate(nil) }
    } label: {
      Image(
        systemName: store.pendingFocusCount == 0
          ? "circle.bottomhalf.filled" : "bubble.left.and.exclamationmark.bubble.right.fill")
    }
  }
}
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
  static var shared: AppDelegate?
  var mainWindow: NSWindow?
  private var notch: NotchController?
  private var wakeObserver: NSObjectProtocol?
  func applicationDidFinishLaunching(_ notification: Notification) {
    Self.shared = self
    NSApp.setActivationPolicy(.regular)
    UNUserNotificationCenter.current().delegate = self
    notch = NotchController(store: AppStore.shared)
    wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
      forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
    ) { _ in
      Task { @MainActor in await AppStore.shared.refreshGroupStates() }
    }
    NSApp.activate(ignoringOtherApps: true)
    Task {
      let store = AppStore.shared
      await store.loadCredentials()
      if !store.alphaToken.isEmpty { await store.connect() }
      if store.preferences.autoStart, store.configured { store.start() }
    }
  }
  func captureWindow() {
    DispatchQueue.main.async {
      self.mainWindow =
        NSApp.windows.first { $0.title == "群岛" && !($0 is NSPanel) } ?? self.mainWindow
    }
  }
  func showMain() {
    captureWindow()
    NSApp.activate(ignoringOtherApps: true)
    if let mainWindow {
      mainWindow.makeKeyAndOrderFront(nil)
    } else {
      NSApp.windows.first(where: { !($0 is NSPanel) })?.makeKeyAndOrderFront(nil)
    }
    Task { await AppStore.shared.refreshGroupStates() }
  }
  func applicationDidBecomeActive(_ notification: Notification) {
    Task { await AppStore.shared.refreshGroupStates() }
  }
  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
  func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool
  {
    showMain()
    return true
  }
  func applicationWillTerminate(_ notification: Notification) {
    if let wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver) }
    AppStore.shared.stopGroupStateRefresh()
    AppStore.shared.stop()
    AppStore.shared.save()
    EventLog.shared.write("信息", "应用退出")
  }
  nonisolated func userNotificationCenter(
    _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
    withCompletionHandler completionHandler: @escaping () -> Void
  ) {
    let id = response.notification.request.content.userInfo["attentionID"] as? String
    Task { @MainActor in
      if let id, let item = AppStore.shared.snapshot.attentions.first(where: { $0.id == id }) {
        AppStore.shared.detail = item
      }
      self.showMain()
      completionHandler()
    }
  }
  nonisolated func userNotificationCenter(
    _ center: UNUserNotificationCenter, willPresent notification: UNNotification,
    withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
  ) { completionHandler([.banner, .sound]) }
}
private struct WindowReader: NSViewRepresentable {
  func makeNSView(context: Context) -> NSView {
    let view = NSView()
    DispatchQueue.main.async {
      if let window = view.window {
        AppDelegate.shared?.mainWindow = window
        window.isReleasedWhenClosed = false
      }
    }
    return view
  }
  func updateNSView(_ nsView: NSView, context: Context) {}
}
