import ServiceManagement
import XCTest
@testable import Qundao

final class LoginItemControllerTests: XCTestCase {
  @MainActor
  func testRefreshFollowsSystemChangesWithoutRegistering() async {
    let service = FakeLoginItemService()
    let controller = LoginItemController(service: service)
    XCTAssertFalse(controller.requested)
    service.status = .enabled
    controller.refresh()
    XCTAssertTrue(controller.requested)
    service.status = .notRegistered
    controller.refresh()
    XCTAssertFalse(controller.requested)
    XCTAssertEqual(service.registrations, 0)
    XCTAssertEqual(service.unregistrations, 0)
  }

  @MainActor
  func testEnableAndDisableReadBackActualSystemState() async {
    let service = FakeLoginItemService()
    // 已安装但尚未首次注册时，真实系统也可能返回 notFound。
    service.status = .notFound
    let controller = LoginItemController(service: service)
    await controller.setEnabled(true)
    XCTAssertEqual(controller.status, .enabled)
    await controller.setEnabled(true)
    XCTAssertEqual(service.registrations, 1)
    await controller.setEnabled(false)
    XCTAssertEqual(controller.status, .notRegistered)
    await controller.setEnabled(false)
    XCTAssertEqual(service.unregistrations, 1)
    XCTAssertNil(controller.error)
  }

  @MainActor
  func testPendingApprovalIsNotEnabledAndCanBeCancelled() async {
    let service = FakeLoginItemService()
    service.registeredStatus = .requiresApproval
    let controller = LoginItemController(service: service)
    await controller.setEnabled(true)
    XCTAssertTrue(controller.requested)
    XCTAssertTrue(controller.needsApproval)
    XCTAssertNotEqual(controller.status, .enabled)
    await controller.setEnabled(true)
    XCTAssertEqual(service.registrations, 1)
    await controller.setEnabled(false)
    XCTAssertFalse(controller.requested)
    XCTAssertFalse(controller.needsApproval)
  }

  @MainActor
  func testRegistrationFailureDoesNotShowEnabled() async {
    let service = FakeLoginItemService()
    service.failure = NSError(domain: "合成注册错误", code: 1)
    let controller = LoginItemController(service: service)
    await controller.setEnabled(true)
    XCTAssertFalse(controller.requested)
    XCTAssertNotNil(controller.error)
    XCTAssertFalse(controller.changing)
    service.failure = nil
    await controller.setEnabled(true)
    XCTAssertTrue(controller.requested)
    XCTAssertNil(controller.error)
  }

  @MainActor
  func testUnregistrationFailureKeepsActualRegisteredState() async {
    let service = FakeLoginItemService()
    service.status = .enabled
    service.failure = NSError(domain: "合成注销错误", code: 2)
    let controller = LoginItemController(service: service)
    await controller.setEnabled(false)
    XCTAssertTrue(controller.requested)
    XCTAssertNotNil(controller.error)
    XCTAssertFalse(controller.changing)
    service.status = .notRegistered
    controller.refresh()
    XCTAssertFalse(controller.requested)
    XCTAssertNil(controller.error)
  }

  @MainActor
  func testRepeatedToggleCannotRacePendingUnregistration() async {
    let service = FakeLoginItemService()
    service.status = .enabled
    service.pauseUnregister = true
    let started = expectation(description: "注销已开始")
    service.onUnregister = { started.fulfill() }
    let controller = LoginItemController(service: service)
    let operation = Task { await controller.setEnabled(false) }
    await fulfillment(of: [started], timeout: 2)
    XCTAssertTrue(controller.changing)
    await controller.setEnabled(true)
    XCTAssertEqual(service.registrations, 0)
    service.unregisterGate?.resume()
    await operation.value
    XCTAssertFalse(controller.requested)
    XCTAssertFalse(controller.changing)
  }
}

@MainActor
private final class FakeLoginItemService: LoginItemService {
  var status: SMAppService.Status = .notRegistered
  var registeredStatus: SMAppService.Status = .enabled
  var registrations = 0
  var unregistrations = 0
  var failure: Error?
  var pauseUnregister = false
  var onUnregister: (() -> Void)?
  var unregisterGate: CheckedContinuation<Void, Never>?
  func register() throws {
    registrations += 1
    if let failure { throw failure }
    status = registeredStatus
  }
  func unregister() async throws {
    unregistrations += 1
    if let failure { throw failure }
    if pauseUnregister {
      await withCheckedContinuation { unregisterGate = $0; onUnregister?() }
    }
    status = .notRegistered
  }
}
