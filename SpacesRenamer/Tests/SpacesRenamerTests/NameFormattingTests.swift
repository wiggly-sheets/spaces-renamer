import XCTest
@testable import SpacesRenamer

final class NameFormattingTests: XCTestCase {
  private func space(
    _ id: String,
    appNames: [String] = [],
    yabaiLabel: String? = nil
  ) -> ManagedSpace {
    ManagedSpace(
      id: id,
      managedID: Int(id) ?? 0,
      index: 1,
      isCurrent: true,
      appNames: appNames,
      yabaiLabel: yabaiLabel
    )
  }

  private func snapshot(_ spaces: [ManagedSpace]) -> [DisplaySpaces] {
    [DisplaySpaces(id: "display-1", name: "Spaces", spaces: spaces)]
  }

  private func generated(
    _ spaces: [ManagedSpace],
    mode: NamingMode
  ) -> [String: String] {
    PreferencesStore.generatedNames(from: snapshot(spaces), namingMode: mode)
  }

  func testManualModeGeneratesNothing() {
    XCTAssertTrue(generated([space("s1", appNames: ["Safari"])], mode: .manual).isEmpty)
    XCTAssertTrue(
      PreferencesStore.generatedNames(from: [], namingMode: .manual).isEmpty
    )
  }

  func testApplicationsJoinWithSeparatorAndCapAtThreeNames() {
    let names = generated(
      [space("s1", appNames: ["Code", "Browser", "Mail", "Music"])],
      mode: .applications
    )
    XCTAssertEqual(names["s1"], "Code · Browser · Mail")
  }

  func testApplicationsSkipsSpacesWithoutWindows() {
    let names = generated(
      [space("s1", appNames: ["Safari"]), space("s2"), space("s3", appNames: [])],
      mode: .applications
    )
    XCTAssertEqual(names, ["s1": "Safari"])
  }

  func testApplicationsPassesThroughDuplicateWindows() {
    // The every-window variant keeps duplicates at the filter layer; the
    // formatting layer must not collapse them.
    let names = generated(
      [space("s1", appNames: ["Safari", "Safari"])],
      mode: .applications
    )
    XCTAssertEqual(names["s1"], "Safari · Safari")
  }

  func testYabaiLabelsPassThrough() {
    let names = generated(
      [space("s1", yabaiLabel: "Design"), space("s2", yabaiLabel: "Terminal")],
      mode: .yabaiLabels
    )
    XCTAssertEqual(names, ["s1": "Design", "s2": "Terminal"])
  }

  func testYabaiLabelsSkipEmptyAndMissingLabels() {
    let names = generated(
      [space("s1", yabaiLabel: nil), space("s2", yabaiLabel: "")],
      mode: .yabaiLabels
    )
    XCTAssertTrue(names.isEmpty)
  }

  func testEmptySnapshotGeneratesNothing() {
    XCTAssertTrue(generated([], mode: .applications).isEmpty)
    XCTAssertTrue(generated([], mode: .yabaiLabels).isEmpty)
  }
}