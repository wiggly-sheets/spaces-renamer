import XCTest

@testable import SpacesRenamer

final class NativeAppManagementTests: XCTestCase {
  private let home = URL(fileURLWithPath: "/Users/me", isDirectory: true)

  func testSystemApplicationsFolderCounts() {
    XCTAssertTrue(
      NativeAppManagement.isInApplications(
        path: "/Applications/SpacesRenamer.app",
        homeDirectory: home
      )
    )
  }

  func testUserApplicationsFolderCounts() {
    XCTAssertTrue(
      NativeAppManagement.isInApplications(
        path: "/Users/me/Applications/SpacesRenamer.app",
        homeDirectory: home
      )
    )
  }

  func testLookalikeAndOutsideFoldersDoNotCount() {
    XCTAssertFalse(
      NativeAppManagement.isInApplications(
        path: "/Users/me/Applications-old/SpacesRenamer.app",
        homeDirectory: home
      )
    )
    XCTAssertFalse(
      NativeAppManagement.isInApplications(
        path: "/Users/me/Downloads/SpacesRenamer.app",
        homeDirectory: home
      )
    )
    XCTAssertFalse(
      NativeAppManagement.isInApplications(path: "/Applications", homeDirectory: home)
    )
  }
}
