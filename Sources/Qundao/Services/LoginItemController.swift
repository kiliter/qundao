import Observation
import ServiceManagement

@MainActor
protocol LoginItemService {
  var status: SMAppService.Status { get }
  func register() throws
  func unregister() async throws
}

@MainActor
private struct MainAppLoginItemService: LoginItemService {
  var status: SMAppService.Status { SMAppService.mainApp.status }
  func register() throws { try SMAppService.mainApp.register() }
  func unregister() async throws { try await SMAppService.mainApp.unregister() }
}

/// 系统登录项是唯一状态来源，不在本地保存一个可能过期的启用标记。
@MainActor @Observable
final class LoginItemController {
  private(set) var status: SMAppService.Status
  private(set) var changing = false
  private(set) var error: String?
  @ObservationIgnored private let service: any LoginItemService

  convenience init() { self.init(service: MainAppLoginItemService()) }
  init(service: any LoginItemService) {
    self.service = service
    status = service.status
  }

  /// 已申请但尚未批准时保留开关，用户仍可关闭以撤销申请；提示必须说明尚未生效。
  var requested: Bool { status == .enabled || status == .requiresApproval }
  var needsApproval: Bool { status == .requiresApproval }

  func refresh() {
    let current = service.status
    if status != current { status = current; error = nil }
  }

  func setEnabled(_ enabled: Bool) async {
    guard !changing else { return }
    changing = true
    error = nil
    refresh()
    defer { refresh(); changing = false }
    do {
      if enabled {
        if !requested { try service.register() }
      } else if requested {
        try await service.unregister()
      }
    } catch {
      self.error = "开机自启设置失败：\(error.localizedDescription)"
    }
  }
}
