// swift-tools-version:6.0
import PackageDescription

let package = Package(
  name: "SpacesRenamer",
  platforms: [.macOS("14.0")],
  targets: [
    .target(
      name: "CGSPrivate",
      path: "CGSPrivate",
      linkerSettings: [.linkedFramework("CoreGraphics")]
    ),
    .executableTarget(
      name: "SpacesRenamer",
      dependencies: ["CGSPrivate"],
      path: ".",
      // Sources are Swift 5 mode under the Xcode project (SWIFT_VERSION 5.0);
      // keep the same language mode here until the 3b migration.
      exclude: ["CGSPrivate", "Assets.xcassets", "Info.plist", "SpacesRenamer.entitlements", "SpacesRenamerBridge.h"],
      swiftSettings: [.swiftLanguageMode(.v5)]
    ),
  ]
)