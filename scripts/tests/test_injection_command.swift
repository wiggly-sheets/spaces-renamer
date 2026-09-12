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
struct InjectionCommandRegressionTests {
  static func main() throws {
    let artifacts = InjectionArtifactSet(
      injectorURL: URL(fileURLWithPath: "/tmp/App's Resources/dylinject"),
      payloadURL: URL(fileURLWithPath: "/tmp/App's Resources/spaces-renamer.dylib"),
      injectorHash: String(repeating: "a", count: 64),
      payloadHash: String(repeating: "b", count: 64)
    )
    let command = InjectionCommandBuilder.privilegedCommand(for: artifacts)
    expect("the command creates a private root staging directory", command.contains("umask 077"))
    expect("the injector is staged non-writable", command.contains("install -m 0500"))
    expect("the staged injector hash is verified", command.contains(artifacts.injectorHash))
    expect("the staged payload hash is verified", command.contains(artifacts.payloadHash))
    expect(
      "only the staged injector is executed",
      command.contains("\"$stage/dylinject\" com.apple.dock")
    )

    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/sh")
    process.arguments = ["-n"]
    let input = Pipe()
    process.standardInput = input
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try process.run()
    input.fileHandleForWriting.write(Data(command.utf8))
    try input.fileHandleForWriting.close()
    process.waitUntilExit()
    expect("the generated privileged shell command parses", process.terminationStatus == 0)

    if failures > 0 { exit(1) }
  }
}
