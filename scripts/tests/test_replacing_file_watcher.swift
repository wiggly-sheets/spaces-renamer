import Darwin
import Foundation

private var failures = 0

private func fail(_ description: String) {
  failures += 1
  print("FAIL - \(description)")
}

private func waitUntil(
  _ description: String,
  timeout: TimeInterval = 2,
  condition: @escaping () -> Bool
) {
  let deadline = Date().addingTimeInterval(timeout)
  while !condition(), Date() < deadline {
    RunLoop.main.run(until: Date().addingTimeInterval(0.02))
  }
  if condition() {
    print("ok - \(description)")
  } else {
    fail(description)
  }
}

@main
struct ReplacingFileWatcherRegressionTests {
  static func main() throws {
    let fileManager = FileManager.default
    let directory = fileManager.temporaryDirectory
      .appendingPathComponent("SpacesRenamerWatcherTests-\(UUID().uuidString)")
    try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? fileManager.removeItem(at: directory) }

    let watchedFile = directory.appendingPathComponent("config.toml")
    try "old".write(to: watchedFile, atomically: false, encoding: .utf8)
    var observedContents: [String] = []
    let watcher = ReplacingFileWatcher(
      fileURL: watchedFile,
      onChange: {
        if let contents = try? String(contentsOf: watchedFile, encoding: .utf8) {
          observedContents.append(contents)
        }
      },
      onError: { fail("watcher reported error: \($0)") }
    )
    watcher.start()

    let replacement = directory.appendingPathComponent("replacement.toml")
    try "atomic".write(to: replacement, atomically: false, encoding: .utf8)
    guard rename(replacement.path, watchedFile.path) == 0 else {
      throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
    }
    waitUntil("atomic file replacement triggers a reload") {
      observedContents.contains("atomic")
    }

    try "reopened".write(to: watchedFile, atomically: false, encoding: .utf8)
    waitUntil("the watcher follows the replacement inode") {
      observedContents.contains("reopened")
    }
    watcher.stop()

    if failures > 0 { exit(1) }
  }
}
