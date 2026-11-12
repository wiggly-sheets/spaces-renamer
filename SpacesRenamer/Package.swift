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
      exclude: ["CGSPrivate", "AppIcon.icon", "Info.plist", "SpacesRenamer.entitlements", "SpacesRenamerBridge.h", "Tests"],
      swiftSettings: [.swiftLanguageMode(.v5)],
      linkerSettings: [
        // macOS chooses the control design from the SDK version recorded in
        // the binary's LC_BUILD_VERSION. Xcode 27's SwiftPM stamps the
        // package's deployment target (14.0) into that field, which silently
        // selects the pre-Tahoe design even though the build uses a newer SDK.
        // Stamp the macOS 26 floor explicitly; glassEffect itself requires a
        // 26+ SDK to compile, so lower SDKs can never reach this flag.
        .unsafeFlags([
          "-Xlinker", "-platform_version",
          "-Xlinker", "macos",
          "-Xlinker", "14.0",
          "-Xlinker", "26.0",
        ])
      ]
    ),
    .testTarget(
      name: "SpacesRenamerTests",
      dependencies: ["SpacesRenamer"],
      swiftSettings: [.swiftLanguageMode(.v5)]
    ),
  ]
)