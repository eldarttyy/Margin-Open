// swift-tools-version:6.0
import PackageDescription

let settings: [SwiftSetting] = [
    .swiftLanguageMode(.v5),
]

let package = Package(
    name: "Margin",
    platforms: [.macOS(.v15)],
    targets: [
        // Thin dlopen shim over Apple's private frameworks.
        .target(name: "CMargin"),
        // Pure gesture and configuration logic. No AppKit, no hardware.
        .target(name: "MarginCore", swiftSettings: settings),
        .executableTarget(name: "Margin", dependencies: ["CMargin", "MarginCore"], swiftSettings: settings),
        // The Command Line Tools ship this plugin outside SwiftPM's search path.
        .testTarget(name: "MarginCoreTests", dependencies: ["MarginCore"], swiftSettings: settings + [
            .unsafeFlags(["-plugin-path", "/Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing"]),
        ]),
    ]
)
