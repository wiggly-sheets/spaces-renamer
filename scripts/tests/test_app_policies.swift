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
struct AppPolicyRegressionTests {
  static func main() throws {
    let queryURL = URL(
      string: "spacesrenamer://space/space-1/name?name=%2520&name=second"
    )!
    expect(
      "duplicate query items are preserved without trapping",
      queryURL.queryValues(named: "name") == ["%20", "second"]
    )
    expect(
      "query values are decoded exactly once",
      queryURL.firstQueryValue(named: "name") == "%20"
    )

    let fileManager = FileManager.default
    let root = fileManager.temporaryDirectory
      .appendingPathComponent("SpacesRenamerPolicyTests-\(UUID().uuidString)", isDirectory: true)
    try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? fileManager.removeItem(at: root) }

    let userID = getuid()
    let requestDirectory = root.appendingPathComponent(
      "spaces-renamer-cli-\(userID).ABC123",
      isDirectory: true
    )
    try fileManager.createDirectory(
      at: requestDirectory,
      withIntermediateDirectories: false,
      attributes: [.posixPermissions: 0o700]
    )
    let reply = requestDirectory.appendingPathComponent("response.json")
    expect(
      "a private request-scoped reply path is accepted",
      CLIReplyPathPolicy.validatedURL(
        path: reply.path,
        userID: userID,
        temporaryRoots: [root]
      ) == reply.standardizedFileURL
    )

    try Data().write(to: reply)
    expect(
      "an existing reply entry is rejected",
      CLIReplyPathPolicy.validatedURL(
        path: reply.path,
        userID: userID,
        temporaryRoots: [root]
      ) == nil
    )
    try fileManager.removeItem(at: reply)

    let unrelated = root.appendingPathComponent("unrelated/response.json")
    try fileManager.createDirectory(
      at: unrelated.deletingLastPathComponent(),
      withIntermediateDirectories: false,
      attributes: [.posixPermissions: 0o700]
    )
    expect(
      "an unrelated temporary directory is rejected",
      CLIReplyPathPolicy.validatedURL(
        path: unrelated.path,
        userID: userID,
        temporaryRoots: [root]
      ) == nil
    )

    let bundleResource = root.appendingPathComponent(
      "Current/SpacesRenamer.app/Contents/Resources/sr"
    )
    try fileManager.createDirectory(
      at: bundleResource.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try Data("current".utf8).write(to: bundleResource)

    let unrelatedFile = root.appendingPathComponent("unrelated-sr")
    try Data("user-owned".utf8).write(to: unrelatedFile)
    expect(
      "an unrelated existing CLI file is preserved",
      ManagedSymlinkInstaller.install(
        at: unrelatedFile,
        to: bundleResource,
        resourcePathWithinBundle: "sr"
      ) == .preserved
    )
    let preservedContents = try Data(contentsOf: unrelatedFile)
    expect(
      "preserving an unrelated file keeps its contents",
      preservedContents == Data("user-owned".utf8)
    )

    let danglingLink = root.appendingPathComponent("dangling-sr")
    let oldResource = root.appendingPathComponent(
      "Old/SpacesRenamer.app/Contents/Resources/sr"
    )
    try fileManager.createSymbolicLink(
      at: danglingLink,
      withDestinationURL: oldResource
    )
    expect(
      "a dangling Spaces Renamer symlink is repaired",
      ManagedSymlinkInstaller.install(
        at: danglingLink,
        to: bundleResource,
        resourcePathWithinBundle: "sr"
      ) == .replaced
    )
    expect(
      "the repaired symlink targets the current bundle resource",
      danglingLink.resolvingSymlinksInPath() == bundleResource.standardizedFileURL
    )

    if failures > 0 { exit(1) }
  }
}
