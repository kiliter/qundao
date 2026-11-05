import AppKit
import Combine

@MainActor final class MenuPlaceholders: NSObject, ObservableObject {
  static let shared = MenuPlaceholders()
  private let key = "群岛.菜单栏占位图标"
  private var items: [String: NSStatusItem] = [:]
  // 旧版已摆好的小图标保持原尺寸，只有新添加的占位项跟随刘海。
  private let wideKey = "群岛.等宽占位图标"
  private var wideIDs: Set<String>
  private let widthKey = "群岛.占位图标自定宽度"
  @Published private(set) var customWidth: CGFloat?
  @Published private var compactWidth: CGFloat = 242
  var width: CGFloat { customWidth ?? compactWidth }

  private var ids: [String]
  private let defaults: UserDefaults
  private var editingWidth = false
  private var savedWidth: CGFloat?
  private var resizeScheduled = false

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
    ids = defaults.stringArray(forKey: key) ?? []
    wideIDs = Set(defaults.stringArray(forKey: wideKey) ?? [])
    customWidth = defaults.object(forKey: widthKey) as? CGFloat
    super.init()
    savedWidth = customWidth
    for id in ids { install(id) }
  }

  func add() {
    let id = UUID().uuidString
    wideIDs.insert(id)
    defaults.set(Array(wideIDs), forKey: wideKey)
    install(id)
    ids.append(id)
    defaults.set(ids, forKey: key)
  }

  func resize(to width: CGFloat) {
    guard compactWidth != width else { return }
    compactWidth = width
    if customWidth == nil { scheduleResize() }
  }

  func setCustomWidth(_ value: CGFloat?) {
    let next = value.map { max(24, $0.rounded()) }
    guard next != customWidth else { return }
    customWidth = next
    scheduleResize()
    if !editingWidth { saveWidth() }
  }

  func editingChanged(_ editing: Bool) {
    editingWidth = editing
    if !editing { saveWidth() }
  }

  func saveWidth() {
    guard customWidth != savedWidth else { return }
    if let customWidth { defaults.set(Double(customWidth), forKey: widthKey) }
    else { defaults.removeObject(forKey: widthKey) }
    savedWidth = customWidth
  }

  // 拖动期间只向系统提交最新宽度；没有待更新的图标时不启动任务。
  private func scheduleResize() {
    guard !resizeScheduled, !items.isEmpty, !wideIDs.isEmpty else { return }
    resizeScheduled = true
    DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(16)) { [weak self] in
      guard let self else { return }
      self.resizeScheduled = false
      let width = self.width
      for id in self.wideIDs {
        if let item = self.items[id], item.length != width { item.length = width }
      }
    }
  }

  private func install(_ id: String) {
    let item = NSStatusBar.system.statusItem(withLength: wideIDs.contains(id) ? width : NSStatusItem.squareLength)
    item.autosaveName = "群岛占位." + id
    let image = NSImage(systemSymbolName: "circle.bottomhalf.filled", accessibilityDescription: "群岛占位图标")
    image?.isTemplate = true
    item.button?.image = image
    item.button?.toolTip = "群岛占位图标"
    let menu = NSMenu()
    let remove = menu.addItem(withTitle: "移除此占位图标", action: #selector(removeItem(_:)), keyEquivalent: "")
    remove.target = self
    remove.representedObject = id
    item.menu = menu
    items[id] = item
  }

  @objc private func removeItem(_ sender: NSMenuItem) {
    guard let id = sender.representedObject as? String, let item = items.removeValue(forKey: id) else { return }
    NSStatusBar.system.removeStatusItem(item)
    if wideIDs.remove(id) != nil { defaults.set(Array(wideIDs), forKey: wideKey) }
    ids.removeAll { $0 == id }
    defaults.set(ids, forKey: key)
  }
}
