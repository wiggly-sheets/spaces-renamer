import Foundation

struct ConfigProfileIdentity: Equatable {
  let id: UUID
  let name: String
}

enum ConfigPolicyError: LocalizedError {
  case invalidHotkeyKey(Int)

  var errorDescription: String? {
    switch self {
    case .invalidHotkeyKey(let value):
      return "hotkey_key must be between 0 and \(UInt32.max), not \(value)."
    }
  }
}

enum ConfigPolicy {
  static func hotkeyKeyCode(from value: Int) throws -> UInt32 {
    guard let keyCode = UInt32(exactly: value) else {
      throw ConfigPolicyError.invalidHotkeyKey(value)
    }
    return keyCode
  }

  static func matchingProfileID(
    configuredUUID: String?,
    sectionName: String,
    profiles: [ConfigProfileIdentity]
  ) -> UUID? {
    let matchingUUID = configuredUUID
      .flatMap(UUID.init(uuidString:))
      .flatMap { configuredID in
        profiles.first(where: { $0.id == configuredID })?.id
      }
    return matchingUUID ?? profiles.first(where: {
      $0.name.localizedCaseInsensitiveCompare(sectionName) == .orderedSame
    })?.id
  }
}
