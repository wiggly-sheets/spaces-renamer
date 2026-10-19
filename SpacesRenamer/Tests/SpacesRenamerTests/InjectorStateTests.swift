import XCTest
@testable import SpacesRenamer

final class InjectorStateTests: XCTestCase {
  func testStatusOutputParsesMipDaemonAndActiveBackend() {
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
    """)

    XCTAssertEqual(state.host, "WindowManager")
    XCTAssertEqual(state.mipDaemon, true)
    XCTAssertEqual(state.active, .mip)
    XCTAssertTrue(state.mipInstalled)
    XCTAssertTrue(state.mipBundleOn)
  }

  func testStatusOutputReportsMipDaemonDown() {
    let state = InjectorState(statusOutput: """
    host=Dock
    mip_daemon=down
    active=none
    """)

    XCTAssertEqual(state.mipDaemon, false)
    XCTAssertEqual(state.active, .none)
  }

  func testStatusOutputWithoutMipDaemonKeyLeavesItUnknown() {
    let state = InjectorState(statusOutput: """
    host=Dock
    active=none
    """)

    XCTAssertNil(state.mipDaemon)
  }
}
