import XCTest
@testable import SpacesRenamer

@MainActor
final class PreferencesStoreTests: XCTestCase {
  private var directory: URL!

  override func setUpWithError() throws {
    directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("SpacesRenamerTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  }

  override func tearDownWithError() throws {
    try? FileManager.default.removeItem(at: directory)
  }

  private var storeURL: URL {
    directory.appendingPathComponent("preferences.json")
  }

  private func makeStore() -> PreferencesStore {
    PreferencesStore(fileURL: storeURL, publishesToDockDomain: false)
  }

  private func writePreferences(_ json: String) throws {
    try json.write(to: storeURL, atomically: true, encoding: .utf8)
  }

  // MARK: - Preference migration (decode of persisted files)

  func testLegacyAutomaticNamingMapsToApplicationsMode() throws {
    try writePreferences("""
    {
      "profiles": [
        {"id": "11111111-1111-1111-1111-111111111111", "name": "Work",
         "names": {"space-a": "Code"}}
      ],
      "activeProfileID": "11111111-1111-1111-1111-111111111111",
      "automaticNaming": true,
      "hotkey": {"keyCode": 15, "command": false, "option": true, "control": true, "shift": false}
    }
    """)

    let store = makeStore()
    XCTAssertEqual(store.namingMode, .applications)
    XCTAssertEqual(store.profiles.count, 1)
    XCTAssertEqual(store.activeProfile.name, "Work")
    XCTAssertEqual(store.name(for: "space-a"), "Code")
    // Fields absent from the legacy format fall back to current defaults.
    XCTAssertTrue(store.showMenuBarIcon)
    XCTAssertEqual(store.menuBarDisplayMode, .icon)
    XCTAssertFalse(store.showDuplicateApplications)
    XCTAssertTrue(store.showSpaceChangeHUD)
    XCTAssertFalse(store.automaticInjectionEnabled)
    XCTAssertNil(store.injectionConsentGranted)
  }

  func testMissingAutomaticNamingDefaultsToManualMode() throws {
    try writePreferences("""
    {
      "profiles": [
        {"id": "11111111-1111-1111-1111-111111111111", "name": "Work", "names": {}}
      ],
      "activeProfileID": "11111111-1111-1111-1111-111111111111",
      "hotkey": {"keyCode": 15, "command": false, "option": true, "control": true, "shift": false}
    }
    """)

    XCTAssertEqual(makeStore().namingMode, .manual)
  }

  func testModernNamingModeWinsOverLegacyAutomaticNaming() throws {
    try writePreferences("""
    {
      "profiles": [
        {"id": "11111111-1111-1111-1111-111111111111", "name": "Work", "names": {}}
      ],
      "activeProfileID": "11111111-1111-1111-1111-111111111111",
      "automaticNaming": true,
      "namingMode": "yabaiLabels",
      "hotkey": {"keyCode": 15, "command": false, "option": true, "control": true, "shift": false}
    }
    """)

    XCTAssertEqual(makeStore().namingMode, .yabaiLabels)
  }

  func testInvalidActiveProfileIDFallsBackToFirstProfile() throws {
    try writePreferences("""
    {
      "profiles": [
        {"id": "11111111-1111-1111-1111-111111111111", "name": "Work", "names": {}},
        {"id": "22222222-2222-2222-2222-222222222222", "name": "Home", "names": {}}
      ],
      "activeProfileID": "99999999-9999-9999-9999-999999999999",
      "hotkey": {"keyCode": 15, "command": false, "option": true, "control": true, "shift": false}
    }
    """)

    let store = makeStore()
    XCTAssertEqual(store.activeProfileID, store.profiles[0].id)
    XCTAssertEqual(store.activeProfile.name, "Work")
  }

  func testEmptyProfilesFallsBackToDefaults() throws {
    try writePreferences("""
    {
      "profiles": [],
      "activeProfileID": "11111111-1111-1111-1111-111111111111",
      "hotkey": {"keyCode": 15, "command": false, "option": true, "control": true, "shift": false}
    }
    """)

    let store = makeStore()
    XCTAssertEqual(store.profiles.map(\.name), ["Work", "Home"])
    XCTAssertEqual(store.namingMode, .manual)
  }

  func testDuplicateAndEmptyProfileNamesAreNormalizedOnLoad() throws {
    try writePreferences("""
    {
      "profiles": [
        {"id": "11111111-1111-1111-1111-111111111111", "name": "Work", "names": {}},
        {"id": "22222222-2222-2222-2222-222222222222", "name": "work", "names": {}},
        {"id": "33333333-3333-3333-3333-333333333333", "name": "   ", "names": {}}
      ],
      "activeProfileID": "11111111-1111-1111-1111-111111111111",
      "hotkey": {"keyCode": 15, "command": false, "option": true, "control": true, "shift": false}
    }
    """)

    XCTAssertEqual(makeStore().profiles.map(\.name), ["Work", "work 2", "Profile"])
  }

  // MARK: - Persistence round-trip

  func testSaveThenLoadRoundTripsState() throws {
    let first = makeStore()
    let workID = first.activeProfileID
    first.setName("Code", for: "space-a")
    first.setName("  Padded  ", for: "space-b")
    first.setNamingMode(.applications)
    first.setShowMenuBarIcon(false)
    first.setMenuBarDisplayMode(.spaceNumberAndName)
    first.setShowDuplicateApplications(true)
    first.setShowSpaceChangeHUD(false)
    first.updateHotkey(HotkeyPreference(keyCode: 3, command: true, option: false, control: false, shift: true))

    let second = makeStore()
    XCTAssertEqual(second.profiles, first.profiles)
    XCTAssertEqual(second.activeProfileID, workID)
    XCTAssertEqual(second.namingMode, .applications)
    XCTAssertFalse(second.showMenuBarIcon)
    XCTAssertEqual(second.menuBarDisplayMode, .spaceNumberAndName)
    XCTAssertTrue(second.showDuplicateApplications)
    XCTAssertFalse(second.showSpaceChangeHUD)
    XCTAssertEqual(second.hotkey, HotkeyPreference(keyCode: 3, command: true, option: false, control: false, shift: true))
    XCTAssertEqual(second.name(for: "space-a"), "Code")
    XCTAssertEqual(second.name(for: "space-b"), "Padded")
  }

  // MARK: - Profile switching

  func testSwitchingActiveProfileChangesNameLookupAndRepublishes() throws {
    let store = makeStore()
    let workID = store.activeProfileID
    XCTAssertEqual(store.name(for: "space-a"), "")

    store.setName("Code", for: "space-a")
    store.addProfile(named: "Home")
    let homeID = store.activeProfileID
    store.setName("Writing", for: "space-a")

    var notificationsPosted = 0
    let token = NotificationCenter.default.addObserver(
      forName: .spacesRenamerPreferencesChanged,
      object: store,
      queue: nil
    ) { _ in notificationsPosted += 1 }
    defer { NotificationCenter.default.removeObserver(token) }

    store.activateProfile(workID)
    XCTAssertEqual(store.activeProfileID, workID)
    XCTAssertEqual(store.name(for: "space-a"), "Code")

    store.activateProfile(homeID)
    XCTAssertEqual(store.activeProfileID, homeID)
    XCTAssertEqual(store.name(for: "space-a"), "Writing")
    XCTAssertEqual(notificationsPosted, 2)
  }

  func testApplyNamesDoesNotCorruptOtherProfiles() throws {
    let store = makeStore()
    let workID = store.activeProfileID
    store.addProfile(named: "Home")
    let homeID = store.activeProfileID

    store.applyNames(["space-a": "Code"], toProfile: workID)
    XCTAssertNil(store.profiles.first(where: { $0.id == homeID })?.names["space-a"])

    store.applyNames(["space-a": "Writing", "space-b": "Reading"], toProfile: homeID)
    store.activateProfile(workID)
    XCTAssertEqual(store.name(for: "space-a"), "Code")
    XCTAssertEqual(store.name(for: "space-b"), "")
    store.activateProfile(homeID)
    XCTAssertEqual(store.name(for: "space-a"), "Writing")
    XCTAssertEqual(store.name(for: "space-b"), "Reading")

    // The Work mapping is intact after the Home edits above.
    store.activateProfile(workID)
    XCTAssertEqual(store.name(for: "space-a"), "Code")
  }

  func testSetNameTrimsAndEmptyRemovesMapping() throws {
    let store = makeStore()
    store.setName("  Code  ", for: "space-a")
    XCTAssertEqual(store.name(for: "space-a"), "Code")

    store.setName("", for: "space-a")
    XCTAssertEqual(store.name(for: "space-a"), "")
  }

  func testAddProfileActivatesAndNamesStayUnique() throws {
    let store = makeStore()
    XCTAssertEqual(store.profiles.map(\.name), ["Work", "Home"])
    store.addProfile(named: "Work")
    XCTAssertEqual(store.profiles.map(\.name), ["Work", "Home", "Work 2"])
    // "work" collides case-insensitively with both "Work" and "Work 2".
    store.addProfile(named: "work")
    XCTAssertEqual(store.profiles.map(\.name), ["Work", "Home", "Work 2", "work 3"])
    XCTAssertEqual(store.activeProfile.name, "work 3")
  }

  func testDeleteProfileMovesActiveProfileSafely() throws {
    let store = makeStore()
    let workID = store.activeProfileID
    store.addProfile(named: "Games")
    let gamesID = store.activeProfileID

    // Deleting the non-active profile leaves the active one untouched.
    store.deleteProfile(workID)
    XCTAssertEqual(store.profiles.map(\.name), ["Home", "Games"])
    XCTAssertEqual(store.activeProfileID, gamesID)

    // Deleting the active profile falls back to the neighbor at its index.
    store.deleteProfile(gamesID)
    XCTAssertEqual(store.profiles.map(\.name), ["Home"])
    XCTAssertEqual(store.activeProfileID, store.profiles[0].id)
  }
}