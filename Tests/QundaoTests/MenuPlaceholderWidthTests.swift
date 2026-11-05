import AppKit
import XCTest
@testable import Qundao

final class MenuPlaceholderWidthTests: XCTestCase {
  @MainActor func testDraggingPreviewsWithoutPersistingIntermediateWidths() async throws {
    let suite = "MenuPlaceholderWidthTests." + UUID().uuidString
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let manager = MenuPlaceholders(defaults: defaults)
    manager.resize(to: 242)
    manager.setCustomWidth(250)
    manager.editingChanged(true)
    for width in 251...400 { manager.setCustomWidth(CGFloat(width)) }
    XCTAssertEqual(manager.width, 400)
    XCTAssertEqual(MenuPlaceholders(defaults: defaults).width, 250)
    manager.editingChanged(false)
    XCTAssertEqual(MenuPlaceholders(defaults: defaults).width, 400)
    manager.resize(to: 280)
    XCTAssertEqual(manager.width, 400)
    manager.setCustomWidth(nil)
    XCTAssertEqual(manager.width, 280)
    XCTAssertNil(MenuPlaceholders(defaults: defaults).customWidth)
  }
}
