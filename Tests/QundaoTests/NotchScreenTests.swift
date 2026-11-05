import AppKit
import XCTest
@testable import Qundao

final class NotchScreenTests: XCTestCase {
  private func screen(_ id: String, number: Int = 1, primary: Bool = false, notch: Bool = false,
                      frame: CGRect = CGRect(x: 0, y: 0, width: 1920, height: 1080)) -> NotchScreen {
    NotchScreen(id: id, name: "合成显示器", number: number, isBuiltIn: notch, isPrimary: primary,
      metrics: NotchScreenMetrics(frame: frame, visibleHeight: frame.height - 60,
        hasNotch: notch, notchWidth: notch ? 185 : 90, barHeight: notch ? 37 : 32))
  }

  func testExplicitScreenOverridesNotchAndPrimaryScreen() {
    let builtIn = screen("built-in", primary: true, notch: true)
    let external = screen("external", number: 2)
    XCTAssertEqual(NotchScreen.resolve(preferredID: external.id, screens: [builtIn, external]), external)
    XCTAssertEqual(NotchScreen.resolve(preferredID: builtIn.id, screens: [builtIn, external]), builtIn)
  }

  func testAutomaticSelectionPrefersNotchThenPrimaryWithoutDependingOnFocus() {
    let primary = screen("primary", primary: true)
    let secondary = screen("secondary", number: 2)
    let builtIn = screen("built-in", number: 3, notch: true)
    XCTAssertEqual(NotchScreen.resolve(preferredID: nil, screens: [primary, secondary, builtIn]), builtIn)
    XCTAssertEqual(NotchScreen.resolve(preferredID: nil, screens: [secondary, primary]), primary)
  }

  func testSelectionSurvivesReorderingAndDuplicateDisplayNames() {
    let first = screen("first", primary: true)
    let second = screen("second", number: 2)
    XCTAssertEqual(first.name, second.name)
    XCTAssertNotEqual(first.label, second.label)
    XCTAssertEqual(NotchScreen.resolve(preferredID: second.id, screens: [second, first])?.id, second.id)
  }

  func testDisconnectedScreenFallsBackAndReconnectRestoresSavedSelection() {
    let builtIn = screen("built-in", notch: true)
    let external = screen("external", number: 2, primary: true)
    let preferred = external.id
    XCTAssertEqual(NotchScreen.resolve(preferredID: preferred, screens: [external, builtIn]), external)
    XCTAssertEqual(NotchScreen.resolve(preferredID: preferred, screens: [builtIn]), builtIn)
    XCTAssertEqual(NotchScreen.resolve(preferredID: preferred, screens: [builtIn, external]), external)
  }

  func testNoConnectedScreensDoesNotInventATarget() {
    XCTAssertNil(NotchScreen.resolve(preferredID: nil, screens: []))
    XCTAssertNil(NotchScreen.resolve(preferredID: "disconnected", screens: []))
  }

  func testPanelAnchorsToTopCenterAcrossNegativeAndVerticalScreenCoordinates() {
    let frames = [CGRect(x: -1920, y: -300, width: 1920, height: 1080),
                  CGRect(x: 300, y: 982, width: 1080, height: 1920),
                  CGRect(x: 0, y: 0, width: 1512, height: 982)]
    for frame in frames {
      let metrics = screen("target", notch: frame.minX == 0, frame: frame).metrics
      for size in [CGSize(width: 180, height: 32), CGSize(width: 680, height: 560)] {
        let panel = metrics.panelFrame(size: size)
        XCTAssertEqual(panel.midX, frame.midX)
        XCTAssertEqual(panel.maxY, frame.maxY)
        XCTAssertTrue(frame.contains(panel))
      }
    }
  }

  @MainActor
  func testSelectedExternalScreenUsesItsOwnCameraAndWidthLimits() async throws {
    let builtIn = screen("built-in", primary: true, notch: true)
    let external = screen("external", number: 2, frame: CGRect(x: -600, y: 0, width: 600, height: 900))
    let selected = try XCTUnwrap(NotchScreen.resolve(preferredID: external.id, screens: [builtIn, external]))
    let metrics = selected.metrics
    let layout = NotchBarLayout(centerWidth: metrics.hasNotch ? metrics.notchWidth : 50,
      screenWidth: metrics.frame.width, hasNotch: metrics.hasNotch,
      preferredCompactWidth: 5000, preferredExpandedWidth: 680, active: true, count: 999)
    XCTAssertEqual(layout.centerWidth, 50)
    XCTAssertEqual(layout.expandedWidth, 576)
    XCTAssertLessThanOrEqual(layout.compactWidth, 576)
    XCTAssertEqual(metrics.barHeight, 32)
  }
}
