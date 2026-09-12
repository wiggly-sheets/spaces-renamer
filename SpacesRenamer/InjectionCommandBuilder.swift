import Foundation

struct InjectionArtifactSet {
  let injectorURL: URL
  let payloadURL: URL
  let injectorHash: String
  let payloadHash: String
}

enum InjectionCommandBuilder {
  static func privilegedCommand(for artifacts: InjectionArtifactSet) -> String {
    let injectorPath = shellQuoted(artifacts.injectorURL.path)
    let payloadPath = shellQuoted(artifacts.payloadURL.path)
    let injectorHash = shellQuoted(artifacts.injectorHash)
    let payloadHash = shellQuoted(artifacts.payloadHash)
    return [
      "set -eu",
      "umask 077",
      "stage=$(/usr/bin/mktemp -d /private/tmp/spaces-renamer-injection.XXXXXX)",
      "cleanup() { /bin/rm -rf \"$stage\"; }",
      "trap cleanup EXIT HUP INT TERM",
      "/usr/bin/install -m 0500 \(injectorPath) \"$stage/dylinject\"",
      "/usr/bin/install -m 0500 \(payloadPath) \"$stage/spaces-renamer.dylib\"",
      "[ \"$(/usr/bin/shasum -a 256 \"$stage/dylinject\" | /usr/bin/cut -d ' ' -f 1)\" = \(injectorHash) ] || { echo 'Injector integrity check failed.' >&2; exit 1; }",
      "[ \"$(/usr/bin/shasum -a 256 \"$stage/spaces-renamer.dylib\" | /usr/bin/cut -d ' ' -f 1)\" = \(payloadHash) ] || { echo 'Payload integrity check failed.' >&2; exit 1; }",
      "/usr/bin/xattr -c \"$stage/dylinject\"",
      "/usr/bin/xattr -c \"$stage/spaces-renamer.dylib\"",
      "\"$stage/dylinject\" com.apple.dock \"$stage/spaces-renamer.dylib\"",
    ].joined(separator: "\n")
  }

  private static func shellQuoted(_ value: String) -> String {
    "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
  }
}
