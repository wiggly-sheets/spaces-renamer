import Foundation

// MARK: - TOMLValue

public enum TOMLValue: Equatable {
  case string(String)
  case bool(Bool)
  case int(Int)
  case float(Double)

  public var stringValue: String? {
    if case .string(let s) = self { return s }; return nil
  }
  public var boolValue: Bool? {
    if case .bool(let b) = self { return b }; return nil
  }
  public var intValue: Int? {
    if case .int(let i) = self { return i }; return nil
  }
}

// MARK: - TOML Parser / Encoder

public struct TOML {
  public enum Error: Swift.Error, LocalizedError {
    case parse(String)
    public var errorDescription: String? {
      switch self { case .parse(let s): return s }
    }
  }

  /// Parse TOML string into nested dictionary:
  /// `[section: [subsection: [key: value]]]`
  public static func parse(_ string: String) throws -> [String: [String: [String: TOMLValue]]] {
    var result: [String: [String: [String: TOMLValue]]] = [:]
    var section = ""
    var subsection = ""

    for line in string.components(separatedBy: .newlines) {
      let trimmed = line.trimmingCharacters(in: .whitespaces)
      guard !trimmed.isEmpty else { continue }

      // Skip comment lines
      if trimmed.hasPrefix("#") { continue }

      // Section header: [section] or [section.subsection]
      if trimmed.hasPrefix("[") {
        guard trimmed.hasSuffix("]") else {
          throw Error.parse("Invalid section header: \(trimmed)")
        }
        let inner = trimmed.dropFirst().dropLast().trimmingCharacters(in: .whitespaces)
        guard !inner.isEmpty else { throw Error.parse("Empty section name") }

        if let dot = inner.firstIndex(of: ".") {
          section = String(inner[..<dot]).trimmingCharacters(in: .whitespaces)
          subsection = String(inner[inner.index(after: dot)...]).trimmingCharacters(in: .whitespaces)
        } else {
          section = String(inner)
          subsection = ""
        }

        guard !section.isEmpty else { throw Error.parse("Empty section name") }

        if result[section] == nil { result[section] = [:] }
        if result[section]![subsection] == nil { result[section]![subsection] = [:] }
        continue
      }

      // key = value
      guard let eq = trimmed.firstIndex(of: "=") else {
        throw Error.parse("Invalid line (no '=' found): \(trimmed)")
      }

      let rawKey = String(trimmed[..<eq]).trimmingCharacters(in: .whitespaces)
      let rawVal = String(trimmed[trimmed.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
      guard !rawKey.isEmpty else { throw Error.parse("Empty key") }

      let key: String
      if rawKey.hasPrefix("\"") {
        let (parsed, remainder) = try extractQuotedString(rawKey, label: "key")
        let rem = remainder.trimmingCharacters(in: .whitespaces)
        guard rem.isEmpty else { throw Error.parse("Unexpected content after key: \(rem)") }
        key = parsed
      } else {
        key = rawKey
      }

      let value = try parseValue(rawVal)
      result[section, default: [:]][subsection, default: [:]][key] = value
    }

    return result
  }

  /// Encode nested dictionary back to TOML string.
  public static func encode(_ data: [String: [String: [String: TOMLValue]]]) -> String {
    var lines: [String] = []
    for section in data.keys.sorted() {
      let subs = data[section]!
      for sub in subs.keys.sorted() {
        let kv = subs[sub]!
        guard !kv.isEmpty else { continue }

        if sub.isEmpty {
          lines.append("[\(section)]")
        } else {
          lines.append("[\(section).\(sub)]")
        }

        for key in kv.keys.sorted() {
          let encodedKey = needsQuoting(key) ? "\"\(key)\"" : key
          lines.append("\(encodedKey) = \(encodeValue(kv[key]!))")
        }
        lines.append("")
      }
    }

    // Trim trailing blank lines
    while lines.last == "" { lines.removeLast() }
    if !lines.isEmpty { lines.append("") }
    return lines.joined(separator: "\n")
  }

  // MARK: - Private Helpers

  /// Whether a bare key needs quoting (contains dots or spaces).
  private static func needsQuoting(_ key: String) -> Bool {
    key.contains(".") || key.contains(" ")
  }

  /// Extract a double-quoted string from the start of `s`.
  /// Returns (unescaped content, remainder after closing quote).
  private static func extractQuotedString(_ s: String, label: String = "value") throws -> (String, String) {
    var idx = s.startIndex
    guard idx < s.endIndex, s[idx] == "\"" else {
      throw Error.parse("\(label) must start with \"")
    }
    idx = s.index(after: idx)

    var result = ""
    var escaped = false

    while idx < s.endIndex {
      let ch = s[idx]
      if escaped {
        switch ch {
        case "n": result.append("\n")
        case "t": result.append("\t")
        case "\\": result.append("\\")
        case "\"": result.append("\"")
        default: result.append(ch)
        }
        escaped = false
      } else if ch == "\\" {
        escaped = true
      } else if ch == "\"" {
        let remainder = String(s[s.index(after: idx)...])
        return (result, remainder)
      } else {
        result.append(ch)
      }
      idx = s.index(after: idx)
    }

    throw Error.parse("Unterminated \(label): \(s)")
  }

  /// Parse a TOML value from raw text.
  private static func parseValue(_ raw: String) throws -> TOMLValue {
    let trimmed = raw.trimmingCharacters(in: .whitespaces)

    // Quoted string
    if trimmed.hasPrefix("\"") {
      let (strVal, remainder) = try extractQuotedString(trimmed)
      let rem = remainder.trimmingCharacters(in: .whitespaces)
      if !rem.isEmpty && !rem.hasPrefix("#") {
        throw Error.parse("Unexpected content after string: \(rem)")
      }
      return .string(strVal)
    }

    // Strip trailing inline comment
    let cleaned: String
    if let hash = trimmed.firstIndex(of: "#") {
      cleaned = String(trimmed[..<hash]).trimmingCharacters(in: .whitespaces)
    } else {
      cleaned = trimmed
    }

    if cleaned == "true" { return .bool(true) }
    if cleaned == "false" { return .bool(false) }
    if let i = Int(cleaned) { return .int(i) }
    if let d = Double(cleaned) { return .float(d) }

    throw Error.parse("Unrecognized value: \(raw)")
  }

  /// Encode a single TOMLValue as a TOML string.
  private static func encodeValue(_ val: TOMLValue) -> String {
    switch val {
    case .string(let s):
      let escaped = s
        .replacingOccurrences(of: "\\", with: "\\\\")
        .replacingOccurrences(of: "\"", with: "\\\"")
        .replacingOccurrences(of: "\n", with: "\\n")
        .replacingOccurrences(of: "\t", with: "\\t")
      return "\"\(escaped)\""
    case .bool(let b): return b ? "true" : "false"
    case .int(let i): return String(i)
    case .float(let f): return String(f)
    }
  }
}
