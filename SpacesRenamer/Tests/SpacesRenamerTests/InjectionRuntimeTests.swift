import XCTest
@testable import SpacesRenamer

final class InjectionRuntimeTests: XCTestCase {
  func testStatusOutputParsesTheStatusContract() {
    let state = InjectorState(statusOutput: """
    host=WindowManager
    mip_installed=yes
    mip_bundle=on
    arm64e=on
    active=mip
    runtime_root=/Users/me/Library/Application Support/SpacesRenamer/mip
    runtime_installed=on
    runtime_bundle=on
    runtime_loaded=on
    """)

    XCTAssertEqual(state.host, "WindowManager")
    XCTAssertTrue(state.mipInstalled)
    XCTAssertTrue(state.mipBundleOn)
    XCTAssertEqual(state.runtimeRoot, "/Users/me/Library/Application Support/SpacesRenamer/mip")
    XCTAssertEqual(state.runtimeInstalled, true)
    XCTAssertEqual(state.runtimeBundle, true)
    XCTAssertEqual(state.runtimeLoaded, true)
    XCTAssertEqual(state.active, .mip)
  }

  func testStatusOutputReportsRuntimeFlagsOff() {
    let state = InjectorState(statusOutput: """
    host=Dock
    mip_installed=no
    mip_bundle=off
    active=none
    runtime_root=/Users/me/Library/Application Support/SpacesRenamer/mip
    runtime_installed=off
    runtime_bundle=off
    runtime_loaded=off
    """)

    XCTAssertEqual(state.host, "Dock")
    XCTAssertFalse(state.mipInstalled)
    XCTAssertFalse(state.mipBundleOn)
    XCTAssertEqual(state.runtimeInstalled, false)
    XCTAssertEqual(state.runtimeBundle, false)
    XCTAssertEqual(state.runtimeLoaded, false)
    XCTAssertEqual(state.active, .none)
  }

  func testStatusOutputWithoutRuntimeKeysLeavesThemUnknown() {
    let state = InjectorState(statusOutput: """
    host=Dock
    mip_installed=yes
    active=none
    """)

    XCTAssertNil(state.runtimeRoot)
    XCTAssertNil(state.runtimeInstalled)
    XCTAssertNil(state.runtimeBundle)
    XCTAssertNil(state.runtimeLoaded)
  }

  func testRuntimeSummaryNamesTheRootAndTheOffValues() {
    let state = InjectorState(statusOutput: """
    runtime_root=/Users/me/Library/Application Support/SpacesRenamer/mip
    runtime_installed=on
    runtime_bundle=on
    runtime_loaded=off
    """)

    XCTAssertEqual(
      state.runtimeSummary,
      "Runtime: /Users/me/Library/Application Support/SpacesRenamer/mip (installed, bundle installed, loader inactive)"
    )
  }

  func testAPluginMarkerFromAnotherReleaseIsNotCurrent() {
    XCTAssertFalse(
      PluginMarker.versionMatches(markerVersion: "1.0.1", appVersion: "1.2.3")
    )
    XCTAssertTrue(
      PluginMarker.versionMatches(markerVersion: "1.2.3", appVersion: "1.2.3")
    )
  }

  func testDevelopmentBuildVersionSuffixesStillCompareExactly() {
    // The build stamps the app and the payload with the same git-describe
    // version, so a suffix must not be ignored: it identifies the payload.
    XCTAssertFalse(
      PluginMarker.versionMatches(markerVersion: "1.1.1-7-g1b77d6b", appVersion: "1.1.1-8-g0c22f4a")
    )
    XCTAssertTrue(
      PluginMarker.versionMatches(markerVersion: "1.1.1-7-g1b77d6b", appVersion: "1.1.1-7-g1b77d6b")
    )
    XCTAssertTrue(
      PluginMarker.versionMatches(markerVersion: "1.0.1", appVersion: nil)
    )
  }

  func testTheHostProcessFollowsTheMacOSRelease() {
    XCTAssertEqual(Injector.host(forMajorVersion: 26), "Dock")
    XCTAssertEqual(Injector.host(forMajorVersion: 27), "WindowManager")
    XCTAssertEqual(Injector.host(forMajorVersion: 28), "WindowManager")
  }

  func testThePluginMarkerDomainFollowsTheHostProcess() {
    XCTAssertEqual(PluginMarker.hostDomain(forMajorVersion: 26), "com.apple.dock")
    XCTAssertEqual(PluginMarker.hostDomain(forMajorVersion: 27), "com.apple.WindowManager")
    XCTAssertEqual(PluginMarker.hostDomain(forMajorVersion: 28), "com.apple.WindowManager")
  }

  func testThePrivateLoaderLivesInApplicationSupport() {
    let expected = FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent("Library/Application Support/SpacesRenamer/mip").path
    XCTAssertEqual(Injector.privateMIPRoot, expected)
  }
}
