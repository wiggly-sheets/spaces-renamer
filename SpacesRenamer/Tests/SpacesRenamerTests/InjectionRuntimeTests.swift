import XCTest
@testable import SpacesRenamer

final class InjectionRuntimeTests: XCTestCase {
  func testStatusOutputParsesTheStatusContract() {
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
    runtime_hooked=on
    runtime_bundle=on
    runtime_service=com.wiggly-sheets.spaces-renamer.injectd
    """)

    XCTAssertEqual(state.host, "WindowManager")
    XCTAssertTrue(state.mipInstalled)
    XCTAssertTrue(state.mipBundleOn)
    XCTAssertEqual(state.mipDaemon, true)
    XCTAssertEqual(state.runtimeRoot, "/Library/SpacesRenamer/mip")
    XCTAssertEqual(state.runtimeInstalled, true)
    XCTAssertEqual(state.runtimeDaemon, true)
    XCTAssertEqual(state.runtimeHooked, true)
    XCTAssertEqual(state.runtimeBundle, true)
    XCTAssertEqual(state.runtimeService, "com.wiggly-sheets.spaces-renamer.injectd")
    XCTAssertEqual(state.active, .mip)
  }

  func testStatusOutputReportsRuntimeFlagsOff() {
    let state = InjectorState(statusOutput: """
    host=Dock
    mip_installed=no
    mip_bundle=off
    active=none
    runtime_root=/Library/Apple/System/Library/Frameworks/mip
    runtime_installed=off
    runtime_daemon=down
    runtime_hooked=off
    runtime_bundle=off
    runtime_service=com.apple.mip.injectd
    mip_daemon=down
    """)

    XCTAssertEqual(state.host, "Dock")
    XCTAssertFalse(state.mipInstalled)
    XCTAssertFalse(state.mipBundleOn)
    XCTAssertEqual(state.runtimeInstalled, false)
    XCTAssertEqual(state.runtimeDaemon, false)
    XCTAssertEqual(state.runtimeHooked, false)
    XCTAssertEqual(state.runtimeBundle, false)
    XCTAssertEqual(state.mipDaemon, false)
    XCTAssertEqual(state.active, .none)
  }

  func testStatusOutputWithoutRuntimeKeysLeavesThemUnknown() {
    let state = InjectorState(statusOutput: """
    host=Dock
    mip_installed=yes
    active=none
    """)

    XCTAssertNil(state.mipDaemon)
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

  func testUnreadableHookStateIsUnknownNotOff() {
    // launchservicesd runs as root; an unprivileged status read cannot inspect its mappings.
    let state = InjectorState(statusOutput: """
    runtime_installed=on
    runtime_daemon=up
    runtime_hooked=unknown
    """)

    XCTAssertNil(state.runtimeHooked)
    XCTAssertTrue(state.runtimeSummary.contains("host hook state unknown"))
  }

  func testAPluginMarkerFromAnotherReleaseIsNotCurrent() {
    XCTAssertFalse(
      PluginMarker.versionMatches(markerVersion: "1.0.1", appVersion: "1.2.3")
    )
    XCTAssertTrue(
      PluginMarker.versionMatches(markerVersion: "1.2.3", appVersion: "1.2.3")
    )
  }

  func testDevelopmentBuildVersionsAreNeverStale() {
    // Local builds stamp a git-describe suffix onto the app; comparing it to the
    // payload's marketing version would force a reinjection on every launch.
    XCTAssertTrue(
      PluginMarker.versionMatches(markerVersion: "1.0.1", appVersion: "1.1.1-7-g1b77d6b")
    )
    XCTAssertTrue(
      PluginMarker.versionMatches(markerVersion: "1.1.1-dirty", appVersion: "1.1.1")
    )
    XCTAssertTrue(
      PluginMarker.versionMatches(markerVersion: "1.0.1", appVersion: nil)
    )
  }

  func testPreferredBackendUsesMIPOnlyWhenARuntimeIsAvailable() {
    XCTAssertEqual(InjectorBackend.preferred(runtimeEmbedded: true, systemMIPAvailable: false), .mip)
    XCTAssertEqual(InjectorBackend.preferred(runtimeEmbedded: false, systemMIPAvailable: true), .mip)
    XCTAssertEqual(InjectorBackend.preferred(runtimeEmbedded: false, systemMIPAvailable: false), .dyld)
  }

  func testExplicitModeKeepsTheChosenBackend() {
    XCTAssertEqual(InjectionMode.mip.resolve(), .mip)
    XCTAssertEqual(InjectionMode.dyld.resolve(), .dyld)
  }

  func testBackendCaptionNamesTheMethodAndTheRuntime() {
    XCTAssertEqual(
      InjectorBackend.dyld.caption(origin: .none),
      "In use: LaunchAgent (DYLD)"
    )
    XCTAssertEqual(
      InjectorBackend.mip.caption(origin: .privateRuntime),
      "In use: MIP — the private runtime"
    )
    XCTAssertEqual(
      InjectorBackend.mip.caption(origin: .systemMIP),
      "In use: MIP — the system MIP install"
    )
    XCTAssertEqual(
      InjectorBackend.mip.caption(origin: .none),
      "In use: MIP — no runtime installed yet"
    )
  }
}
