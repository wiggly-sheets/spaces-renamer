import Foundation

enum ProfileNamePolicy {
  static func uniqueName(_ base: String, existingNames: [String]) -> String {
    var candidate = base
    var suffix = 2
    while existingNames.contains(where: {
      $0.localizedCaseInsensitiveCompare(candidate) == .orderedSame
    }) {
      candidate = "\(base) \(suffix)"
      suffix += 1
    }
    return candidate
  }

  static func normalizedNames(
    _ storedNames: [String],
    emptyName: String = "Profile"
  ) -> [String] {
    var usedNames: [String] = []
    return storedNames.map { storedName in
      let trimmed = storedName.trimmingCharacters(in: .whitespacesAndNewlines)
      let base = trimmed.isEmpty ? emptyName : trimmed
      let name = uniqueName(base, existingNames: usedNames)
      usedNames.append(name)
      return name
    }
  }
}
