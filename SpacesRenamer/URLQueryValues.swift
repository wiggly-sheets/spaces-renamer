import Foundation

extension URL {
  func queryValues(named name: String) -> [String] {
    guard let components = URLComponents(url: self, resolvingAgainstBaseURL: false),
          let items = components.queryItems else { return [] }
    return items.compactMap { item in
      guard item.name == name else { return nil }
      return item.value
    }
  }

  func firstQueryValue(named name: String) -> String? {
    queryValues(named: name).first
  }
}
