import Darwin
import Foundation

struct CLIReplyPathPolicy {
  static func validatedURL(
    path: String,
    userID: uid_t = getuid(),
    temporaryRoots: [URL]? = nil
  ) -> URL? {
    guard path.hasPrefix("/") else { return nil }

    let destination = URL(fileURLWithPath: path).standardizedFileURL
    let requestDirectory = destination.deletingLastPathComponent()
    let resolvedRequestDirectory = requestDirectory.resolvingSymlinksInPath()
    let resolvedTemporaryRoot = resolvedRequestDirectory
      .deletingLastPathComponent()
      .standardizedFileURL.path
    let roots = temporaryRoots ?? [
      URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true),
      URL(fileURLWithPath: "/private/tmp", isDirectory: true),
    ]
    let allowedTemporaryRoots = roots.map {
      $0.standardizedFileURL.resolvingSymlinksInPath().path
    }
    guard destination.lastPathComponent == "response.json",
          allowedTemporaryRoots.contains(resolvedTemporaryRoot) else { return nil }

    let prefix = "spaces-renamer-cli-\(userID)."
    let directoryName = requestDirectory.lastPathComponent
    guard directoryName.hasPrefix(prefix) else { return nil }
    let token = directoryName.dropFirst(prefix.count)
    guard (6...64).contains(token.count), token.unicodeScalars.allSatisfy({ scalar in
      CharacterSet.alphanumerics.contains(scalar) && scalar.isASCII
    }) else { return nil }

    var directoryInfo = stat()
    guard lstat(requestDirectory.path, &directoryInfo) == 0,
          directoryInfo.st_uid == userID,
          directoryInfo.st_mode & S_IFMT == S_IFDIR,
          directoryInfo.st_mode & 0o077 == 0 else { return nil }

    var destinationInfo = stat()
    guard lstat(destination.path, &destinationInfo) != 0, errno == ENOENT else {
      return nil
    }
    return destination
  }
}
