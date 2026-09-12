import Darwin
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
struct YabaiClientRegressionTests {
  static func main() throws {
    let fileManager = FileManager.default
    let directory = fileManager.temporaryDirectory
      .appendingPathComponent("SpacesRenamerYabaiTests-\(UUID().uuidString)")
    try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? fileManager.removeItem(at: directory) }

    let executable = directory.appendingPathComponent("fake-yabai")
    let script = """
    #!/bin/sh
    case "$1" in
      success) /usr/bin/printf '{"ok":true}' ;;
      failure) exit 7 ;;
      slow) exec /bin/sleep 5 ;;
    esac
    """
    try script.write(to: executable, atomically: true, encoding: .utf8)
    guard chmod(executable.path, 0o700) == 0 else {
      throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
    }

    let output = YabaiClient.run(
      ["success"],
      timeout: 1,
      executableURL: executable
    )
    expect(
      "successful commands return captured output",
      output == Data("{\"ok\":true}".utf8)
    )
    expect(
      "nonzero commands fail without returning output",
      YabaiClient.run(["failure"], timeout: 1, executableURL: executable) == nil
    )

    let start = Date()
    let timedOut = YabaiClient.run(["slow"], timeout: 0.2, executableURL: executable)
    let elapsed = Date().timeIntervalSince(start)
    expect("hung commands time out", timedOut == nil)
    expect("timeouts are bounded", elapsed < 1.5)

    if failures > 0 { exit(1) }
  }
}
