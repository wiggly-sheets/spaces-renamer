import XCTest
@testable import SpacesRenamer

final class InjectionRuntimeTests: XCTestCase {
  func testStatusOutputParsesRuntimeKeys() {
    let state = InjectorState(statusOutput: """
    host=WindowManager
    mip_daemon=up
    runtime_root=/Library/SpacesRenamer/mip
    runtime_installed=on
    runtime_daemon=up
    runtime_hooked=on
    runtime_bundle=on
    runtime_service=com.wiggly-sheets.spaces-renamer.injectd
    active=mip
    """)

    XCTAssertEqual(state.runtimeRoot, "/Library/SpacesRenamer/mip")
    XCTAssertEqual(state.runtimeInstalled, true)
    XCTAssertEqual(state.runtimeDaemon, true)
    XCTAssertEqual(state.runtimeHooked, true)
    XCTAssertEqual(state.runtimeBundle, true)
    XCTAssertEqual(state.runtimeService, "com.wiggly-sheets.spaces-renamer.injectd")
    XCTAssertEqual(state.mipDaemon, true)
  }

  func testStatusOutputReportsRuntimeFlagsOff() {
    let state = InjectorState(statusOutput: """
    runtime_root=/Library/Apple/System/Library/Frameworks/mip
    runtime_installed=off
    runtime_daemon=down
    runtime_hooked=off
    runtime_bundle=off
    runtime_service=com.apple.mip.injectd
    mip_daemon=down
    """)

    XCTAssertEqual(state.runtimeInstalled, false)
    XCTAssertEqual(state.runtimeDaemon, false)
    XCTAssertEqual(state.runtimeHooked, false)
    XCTAssertEqual(state.runtimeBundle, false)
    XCTAssertEqual(state.mipDaemon, false)
  }

  func testStatusOutputWithoutRuntimeKeysLeavesThemUnknown() {
    let state = InjectorState(statusOutput: """
    host=Dock
    mip_installed=yes
    active=none
    """)

    XCTAssertNil(state.runtimeRoot)
    XCTAssertNil(state.runtimeInstalled)
    XCTAssertNil(state.runtimeDaemon)
    XCTAssertNil(state.runtimeHooked)
    XCTAssertNil(state.runtimeBundle)
    XCTAssertNil(state.runtimeService)
  }

  func testRuntimeSummaryNamesTheRootAndTheOffValues() {
    let state = InjectorState(statusOutput: """
    runtime_root=/Library/SpacesRenamer/mip
    runtime_installed=on
    runtime_daemon=down
    runtime_hooked=off
    runtime_bundle=on
    """)

    XCTAssertEqual(
      state.runtimeSummary,
      "Runtime: /Library/SpacesRenamer/mip (installed, daemon down, host hook off, bundle installed)"
    )
  }

  func testRealStatusOutputParsesTheRuntimeKeys() {
    // The shape of `injector.sh status` on a machine with the private runtime.
    let state = InjectorState(statusOutput: """
    host=WindowManager
    dyld_agent=absent
    dyld_env=unset
    dyld=off
    mip_installed=yes
    mip_bundle=on
    mip_daemon=up
    arm64e=on
    active=mip
    runtime_root=/Library/SpacesRenamer/mip
    runtime_installed=on
    runtime_daemon=up
    runtime_hooked=off
    runtime_bundle=on
    runtime_service=com.wiggly-sheets.spaces-renamer.injectd
    """)

    XCTAssertEqual(state.runtimeRoot, "/Library/SpacesRenamer/mip")
    XCTAssertEqual(state.runtimeInstalled, true)
    XCTAssertEqual(state.runtimeDaemon, true)
    XCTAssertEqual(state.runtimeHooked, false)
    XCTAssertEqual(state.runtimeBundle, true)
    XCTAssertEqual(state.runtimeService, "com.wiggly-sheets.spaces-renamer.injectd")
    XCTAssertEqual(state.active, .mip)
  }

  func testPreferredBackendUsesMIPWhenThePrivateRuntimeIsEmbedded() {
    XCTAssertEqual(InjectorBackend.preferred(runtimeEmbedded: true, systemMIPAvailable: false), .mip)
  }

  func testPreferredBackendUsesMIPWhenSystemMIPIsInstalled() {
    XCTAssertEqual(InjectorBackend.preferred(runtimeEmbedded: false, systemMIPAvailable: true), .mip)
  }

  func testPreferredBackendFallsBackToDYLDWithoutAnyRuntime() {
    XCTAssertEqual(InjectorBackend.preferred(runtimeEmbedded: false, systemMIPAvailable: false), .dyld)
  }

  func testExplicitModeKeepsTheChosenBackend() {
    XCTAssertEqual(InjectionMode.mip.resolve(), .mip)
    XCTAssertEqual(InjectionMode.dyld.resolve(), .dyld)
  }
}
