import XCTest
@testable import SpacesRenamer

final class SpaceStoreTests: XCTestCase {
  private func makeWindow(
    id: Int,
    app: String = "Safari",
    space: Int = 1,
    x: Double = 0,
    y: Double = 0,
    w: Double = 100,
    h: Double = 100,
    isHidden: Bool = false,
    isMinimized: Bool = false,
    role: String = "AXWindow",
    subrole: String = "AXStandardWindow",
    rootWindow: Bool? = true,
    isVisible: Bool? = nil
  ) -> [String: Any] {
    var json: [String: Any] = [
      "id": id,
      "app": app,
      "space": space,
      "frame": ["x": x, "y": y, "w": w, "h": h],
      "is-hidden": isHidden,
      "is-minimized": isMinimized,
    ]
    if !role.isEmpty { json["role"] = role }
    if !subrole.isEmpty { json["subrole"] = subrole }
    if let rootWindow { json["root-window"] = rootWindow }
    if let isVisible { json["is-visible"] = isVisible }
    return json
  }

  private func windowsJSON(_ windows: [[String: Any]]) -> Data {
    try! JSONSerialization.data(withJSONObject: windows)
  }

  private func filter(
    _ windows: [[String: Any]],
    spaceIndexToID: [Int: Int] = [1: 100],
    showDuplicateApplications: Bool = false
  ) -> [Int: [String]]? {
    SpaceStore.applicationsByManagedSpace(
      windowsJSON: windowsJSON(windows),
      spaceIndexToID: spaceIndexToID,
      showDuplicateApplications: showDuplicateApplications
    )
  }

  func testOnlyStandardUserWindowsPassThePredicate() {
    let windows = [
      makeWindow(id: 1, app: "Safari", x: 10),
      makeWindow(id: 2, app: "Mail", isHidden: true),
      makeWindow(id: 3, app: "Slack", isMinimized: true),
      makeWindow(id: 4, app: "Notes", w: 0),
      makeWindow(id: 5, app: "Music", h: 0),
      makeWindow(id: 6, app: "Photos", role: ""),       // no role
      makeWindow(id: 7, app: "Calendar", subrole: ""),  // no subrole
      makeWindow(id: 8, app: "Terminal", rootWindow: false),
      makeWindow(id: 9, app: "Dock"),
      makeWindow(id: 10, app: "Spaces Renamer"),
      makeWindow(id: 11, app: "Finder", space: 0),
      makeWindow(id: 12, app: ""),
      makeWindow(id: -13, app: "Xcode"),
    ]

    XCTAssertEqual(filter(windows), [100: ["Safari"]])
  }

  func testIsVisibleFalseIsNotConsulted() {
    // Real windows on inactive Spaces report is-visible false; the predicate
    // must still accept them (documented in AGENTS.md).
    let windows = [makeWindow(id: 1, app: "Safari", isVisible: false)]
    XCTAssertEqual(filter(windows), [100: ["Safari"]])
  }

  func testMissingRootWindowKeyStillPasses() {
    let windows = [makeWindow(id: 1, app: "Safari", rootWindow: nil)]
    XCTAssertEqual(filter(windows), [100: ["Safari"]])
  }

  func testOrderingIsLeftToRightThenTopToBottom() {
    let windows = [
      makeWindow(id: 5, app: "A", x: 0, y: 100),
      makeWindow(id: 6, app: "B", x: 0, y: 0),
      makeWindow(id: 1, app: "C", x: 200, y: 0),
    ]
    XCTAssertEqual(filter(windows), [100: ["B", "A", "C"]])
  }

  func testCrossSpaceOrderingGroupsLowerSpaceFirst() {
    let windows = [
      makeWindow(id: 5, app: "A", space: 1, x: 500),
      makeWindow(id: 6, app: "B", space: 2, x: 0),
    ]
    let result = filter(windows, spaceIndexToID: [1: 100, 2: 200])
    XCTAssertEqual(result?[100], ["A"])
    XCTAssertEqual(result?[200], ["B"])
  }

  func testWindowsOnUnmappedSpaceAreDropped() {
    let windows = [
      makeWindow(id: 1, app: "A", space: 1),
      makeWindow(id: 2, app: "B", space: 3), // no spaceIndexToID entry
    ]
    XCTAssertEqual(filter(windows, spaceIndexToID: [1: 100]), [100: ["A"]])
  }

  func testDuplicateApplicationsDedupedCaseInsensitively() {
    let windows = [
      makeWindow(id: 1, app: "Safari", x: 0),
      makeWindow(id: 2, app: "safari", x: 10),
      makeWindow(id: 3, app: "SaFaRi", x: 20),
    ]
    XCTAssertEqual(filter(windows), [100: ["Safari"]])
  }

  func testDuplicateApplicationsKeptWhenRequested() {
    let windows = [
      makeWindow(id: 1, app: "Safari", x: 0),
      makeWindow(id: 2, app: "Safari", x: 10),
      makeWindow(id: 3, app: "Code", x: 20),
    ]
    XCTAssertEqual(
      filter(windows, showDuplicateApplications: true),
      [100: ["Safari", "Safari", "Code"]]
    )
  }

  func testUndecodableWindowsJSONReturnsNil() {
    let result = SpaceStore.applicationsByManagedSpace(
      windowsJSON: Data("not json".utf8),
      spaceIndexToID: [1: 100],
      showDuplicateApplications: false
    )
    XCTAssertNil(result)
  }
}