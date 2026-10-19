import XCTest
@testable import SpacesRenamer

final class DiagnosticsTests: XCTestCase {
  func testLaunchAgentInjectorPassesWhenArmed() {
    let state = InjectorState(statusOutput: """
    dyld_agent=present
    dyld_env=set
    dyld=on
    """)

    let check = DiagnosticsModel.launchAgentInjector(state: state, libraryStaged: true)

    XCTAssertEqual(check.title, "LaunchAgent injector (backup)")
    XCTAssertEqual(check.status, .pass)
    XCTAssertEqual(check.finding, "armed: login agent present, environment set, library staged")
  }

  func testLaunchAgentInjectorIsUnknownWhenNotArmed() {
    let state = InjectorState(statusOutput: """
    dyld_agent=absent
    dyld_env=unset
    dyld=off
    """)

    let check = DiagnosticsModel.launchAgentInjector(state: state, libraryStaged: false)

    // A backup path that is simply not in use is never a failure.
    XCTAssertEqual(check.status, .unknown)
    XCTAssertNotEqual(check.status, .fail)
    XCTAssertEqual(
      check.finding,
      "not armed: no login agent, environment unset, library not staged. Backup path, used only when MIP is unavailable."
    )
  }

  func testLaunchAgentInjectorFailsWhenArmedButTheLibraryIsMissing() {
    let state = InjectorState(statusOutput: """
    dyld_agent=present
    dyld_env=set
    dyld=on
    """)

    let check = DiagnosticsModel.launchAgentInjector(state: state, libraryStaged: false)

    // Armed, but the payload the environment names is gone: broken, not unused.
    XCTAssertEqual(check.status, .fail)
    XCTAssertTrue(check.finding.contains("staged library is missing"))
  }

  func testLaunchAgentInjectorReportsAnUnreadableStatus() {
    var state = InjectorState()
    state.readError = "Could not read injector status."

    let check = DiagnosticsModel.launchAgentInjector(state: state, libraryStaged: false)

    XCTAssertEqual(check.status, .unknown)
    XCTAssertEqual(check.finding, "Could not read the injector status")
  }

  func testInjectionRuntimePassesWhenTheRuntimeIsInstalledAndRunning() {
    let state = InjectorState(statusOutput: """
    runtime_root=/Library/SpacesRenamer/mip
    runtime_installed=on
    runtime_daemon=up
    runtime_hooked=on
    runtime_bundle=on
    """)

    let check = DiagnosticsModel.injectionRuntime(state)

    XCTAssertEqual(check.title, "Injection runtime")
    XCTAssertEqual(check.status, .pass)
    XCTAssertEqual(
      check.finding,
      "Runtime: /Library/SpacesRenamer/mip (installed, daemon running, host hook on, bundle installed)"
    )
  }

  func testInjectionRuntimeFailsWhenTheRuntimeIsNotInstalled() {
    let state = InjectorState(statusOutput: """
    runtime_root=/Library/SpacesRenamer/mip
    runtime_installed=off
    runtime_daemon=down
    """)

    let check = DiagnosticsModel.injectionRuntime(state)

    XCTAssertEqual(check.status, .fail)
    XCTAssertEqual(check.remedy, DiagnosticsModel.activationRemedy)
  }

  func testInjectionRuntimeFailsWhenTheDaemonIsDown() {
    let state = InjectorState(statusOutput: """
    runtime_root=/Library/SpacesRenamer/mip
    runtime_installed=on
    runtime_daemon=down
    """)

    let check = DiagnosticsModel.injectionRuntime(state)

    XCTAssertEqual(check.status, .fail)
    XCTAssertEqual(
      check.remedy,
      "The runtime is installed, but its daemon is not running. Activate the injection again to start it."
    )
  }

  func testInjectionRuntimeReportsAnUnreadableStatus() {
    var state = InjectorState()
    state.readError = "Could not read injector status."

    let check = DiagnosticsModel.injectionRuntime(state)

    XCTAssertEqual(check.status, .unknown)
    XCTAssertEqual(check.finding, "Could not read the injector status")
  }

  @MainActor
  func testTheInitialListHoldsTheLaunchAgentCheckAfterTheInjectionRuntime() {
    let model = DiagnosticsModel()

    XCTAssertEqual(model.checks.map(\.title), [
      "System Integrity Protection",
      "Boot arguments",
      "Injection runtime",
      "LaunchAgent injector (backup)",
      "Plugin version",
      "Plugin active in host",
    ])
  }

  func testAFinishedRunHoldsTheSameCheckTitlesAsTheInitialList() {
    XCTAssertEqual(DiagnosticsModel.runAll().map(\.title), DiagnosticsModel.checkTitles)
  }
}
