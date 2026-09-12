import Darwin
import Foundation

enum YabaiClient {
  static func findExecutableURL(fileManager: FileManager = .default) -> URL? {
    ["/opt/homebrew/bin/yabai", "/usr/local/bin/yabai"]
      .first(where: { fileManager.isExecutableFile(atPath: $0) })
      .map { URL(fileURLWithPath: $0) }
  }

  static func run(
    _ arguments: [String],
    timeout: TimeInterval = 2,
    captureOutput: Bool = true,
    executableURL: URL? = nil
  ) -> Data? {
    guard timeout > 0,
          let executableURL = executableURL ?? findExecutableURL() else { return nil }

    let process = Process()
    process.executableURL = executableURL
    process.arguments = arguments
    process.standardError = FileHandle.nullDevice

    let outputURL: URL?
    let outputHandle: FileHandle?
    if captureOutput {
      let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("spaces-renamer-yabai-\(UUID().uuidString).output")
      guard FileManager.default.createFile(
        atPath: url.path,
        contents: nil,
        attributes: [.posixPermissions: 0o600]
      ), let handle = try? FileHandle(forWritingTo: url) else { return nil }
      outputURL = url
      outputHandle = handle
      process.standardOutput = handle
    } else {
      outputURL = nil
      outputHandle = nil
      process.standardOutput = FileHandle.nullDevice
    }
    defer {
      try? outputHandle?.close()
      if let outputURL { try? FileManager.default.removeItem(at: outputURL) }
    }

    let completed = DispatchSemaphore(value: 0)
    process.terminationHandler = { _ in completed.signal() }
    do {
      try process.run()
      guard completed.wait(timeout: .now() + timeout) == .success else {
        process.terminate()
        if completed.wait(timeout: .now() + 0.25) == .timedOut, process.isRunning {
          kill(process.processIdentifier, SIGKILL)
          _ = completed.wait(timeout: .now() + 0.25)
        }
        return nil
      }
      guard process.terminationStatus == 0 else { return nil }
      guard let outputURL, let outputHandle else { return Data() }
      try? outputHandle.synchronize()
      try outputHandle.close()
      return try Data(contentsOf: outputURL)
    } catch {
      return nil
    }
  }
}
