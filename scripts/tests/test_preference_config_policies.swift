import Foundation

private var failures = 0

private func expect(_ description: String, _ condition: @autoclosure () -> Bool) {
  if condition() {
    print("ok - \(description)")
  } else {
    failures += 1
    print("FAIL - \(description)")
  }
}

@main
struct PreferenceConfigPolicyRegressionTests {
  static func main() {
    expect(
      "stored duplicate and blank profile names are normalized deterministically",
      ProfileNamePolicy.normalizedNames(["Work", "work", "  "])
        == ["Work", "work 2", "Profile"]
    )
    expect(
      "renaming to an existing profile receives a unique suffix",
      ProfileNamePolicy.uniqueName("Home", existingNames: ["Work", "home"])
        == "Home 2"
    )

    let workID = UUID()
    let homeID = UUID()
    let profiles = [
      ConfigProfileIdentity(id: workID, name: "Work"),
      ConfigProfileIdentity(id: homeID, name: "Home"),
    ]
    expect(
      "config sections can target an inactive profile by name",
      ConfigPolicy.matchingProfileID(
        configuredUUID: nil,
        sectionName: "Home",
        profiles: profiles
      ) == homeID
    )
    expect(
      "a configured profile UUID takes precedence over its section name",
      ConfigPolicy.matchingProfileID(
        configuredUUID: homeID.uuidString,
        sectionName: "Work",
        profiles: profiles
      ) == homeID
    )

    expect(
      "valid hotkey integers convert exactly",
      (try? ConfigPolicy.hotkeyKeyCode(from: 15)) == 15
    )
    expect(
      "negative hotkey integers are rejected instead of trapping",
      (try? ConfigPolicy.hotkeyKeyCode(from: -1)) == nil
    )
    expect(
      "oversized hotkey integers are rejected instead of trapping",
      (try? ConfigPolicy.hotkeyKeyCode(from: Int(UInt32.max) + 1)) == nil
    )

    if failures > 0 { exit(1) }
  }
}
