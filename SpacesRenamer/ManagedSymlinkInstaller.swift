import Darwin
import Foundation

enum ManagedSymlinkInstallOutcome: Equatable {
  case unchanged
  case installed
  case replaced
  case preserved
  case failed(String)
}

struct ManagedSymlinkInstaller {
  static func install(
    at destination: URL,
    to resource: URL,
    resourcePathWithinBundle: String,
    fileManager: FileManager = .default
  ) -> ManagedSymlinkInstallOutcome {
    var destinationInfo = stat()
    let destinationExists = lstat(destination.path, &destinationInfo) == 0
    var replaced = false

    if destinationExists {
      guard destinationInfo.st_mode & S_IFMT == S_IFLNK,
            let rawTarget = try? fileManager.destinationOfSymbolicLink(
              atPath: destination.path
            ) else { return .preserved }

      let target = URL(
        fileURLWithPath: rawTarget,
        relativeTo: destination.deletingLastPathComponent()
      ).standardizedFileURL
      if target.path == resource.standardizedFileURL.path { return .unchanged }
      guard isSpacesRenamerResource(
        target,
        resourcePathWithinBundle: resourcePathWithinBundle
      ) else { return .preserved }

      do {
        try fileManager.removeItem(at: destination)
        replaced = true
      } catch {
        return .failed(error.localizedDescription)
      }
    } else if errno != ENOENT {
      return .failed(String(cString: strerror(errno)))
    }

    do {
      try fileManager.createSymbolicLink(at: destination, withDestinationURL: resource)
      return replaced ? .replaced : .installed
    } catch {
      return .failed(error.localizedDescription)
    }
  }

  private static func isSpacesRenamerResource(
    _ target: URL,
    resourcePathWithinBundle: String
  ) -> Bool {
    let suffix = "/Contents/Resources/\(resourcePathWithinBundle)"
    let path = target.standardizedFileURL.path
    guard path.hasSuffix(suffix) else { return false }
    let bundlePath = String(path.dropLast(suffix.count))
    return URL(fileURLWithPath: bundlePath).lastPathComponent
      .localizedCaseInsensitiveCompare("SpacesRenamer.app") == .orderedSame
  }
}
