// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "loco",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "loco",
            path: "Sources/loco"
        )
    ],
    // Use Swift 5 language mode for the PoC so AppKit's MainActor isolation
    // doesn't turn into hard errors. Tighten to .v6 once the design settles.
    swiftLanguageModes: [.v5]
)
