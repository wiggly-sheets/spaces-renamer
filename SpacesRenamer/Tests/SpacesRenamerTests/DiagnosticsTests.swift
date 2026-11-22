import XCTest
@testable import SpacesRenamer

final class DiagnosticsTests: XCTestCase {
  func testInjectionRuntimePassesWhenTheRuntimeIsInstalledAndRunning() {
    let state = InjectorState(statusOutput: """
    runtime_root=/Users/me/Library/Application Support/SpacesRenamer/mip
    runtime_installed=on
    runtime_bundle=on
    runtime_loaded=on
    """)

    let check = DiagnosticsModel.injectionRuntime(state)

    XCTAssertEqual(check.title, "Injection runtime")
    XCTAssertEqual(check.status, .pass)
    XCTAssertEqual(
      check.finding,
      "Runtime: /Users/me/Library/Application Support/SpacesRenamer/mip (installed, bundle installed, loader active)"
    )
  }

  func testInjectionRuntimeFailsWhenTheRuntimeIsNotInstalled() {
    let state = InjectorState(statusOutput: """
    runtime_root=/Users/me/Library/Application Support/SpacesRenamer/mip
    runtime_installed=off
    runtime_bundle=off
    """)

    let check = DiagnosticsModel.injectionRuntime(state)

    XCTAssertEqual(check.status, .fail)
    XCTAssertEqual(check.remedy, DiagnosticsModel.activationRemedy)
  }

  func testInjectionRuntimeFailsWhenTheBundleIsMissing() {
    let state = InjectorState(statusOutput: """
    runtime_root=/Users/me/Library/Application Support/SpacesRenamer/mip
    runtime_installed=on
    runtime_bundle=off
    runtime_loaded=off
    """)

    let check = DiagnosticsModel.injectionRuntime(state)

    XCTAssertEqual(check.status, .fail)
    XCTAssertEqual(
      check.remedy,
      "The loader is installed, but the bundle is missing. Activate the injection again."
    )
  }

  func testInjectionRuntimeIsUnknownWhenTheLoaderIsNotLoaded() {
    let state = InjectorState(statusOutput: """
    runtime_root=/Users/me/Library/Application Support/SpacesRenamer/mip
    runtime_installed=on
    runtime_bundle=on
    runtime_loaded=off
    """)

    let check = DiagnosticsModel.injectionRuntime(state)

    XCTAssertEqual(check.status, .unknown)
    XCTAssertEqual(
      check.remedy,
      "The loader and bundle are installed, but the host has not loaded them. Activate the injection again."
    )
  }

  func testInjectionRuntimeReportsAnUnreadableStatus() {
    var state = InjectorState()
    state.readError = "Could not read injector status."

    let check = DiagnosticsModel.injectionRuntime(state)

    XCTAssertEqual(check.status, .unknown)
    XCTAssertEqual(check.finding, "Could not read the injector status")
  }

  func testAFinishedRunKeepsTheInitialCheckOrder() {
    XCTAssertEqual(DiagnosticsModel.runAll().map(\.title), DiagnosticsModel.checkTitles)
  }
}
