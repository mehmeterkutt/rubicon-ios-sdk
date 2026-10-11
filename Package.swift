// swift-tools-version: 6.0
// The minimum toolchain is Swift 6.0 (Xcode 16), never above what the App Store requires
// (iOS Public API 2). One manifest, no versioned fallbacks.
import PackageDescription

let package = Package(
    name: "Rubicon",
    platforms: [
        // iOS 15 is the floor (iOS Public API 2). iOS is the only supported platform (iOS Public
        // API 8); the macOS entry is not support, it pins the deployment target of the host build
        // that `swift test` uses to the same OS generation as iOS 15, so that an API available on
        // iOS 15 compiles there and the toolchain's default (10.13 on Xcode 26, 14 on Xcode 27)
        // does not decide what the core may call (plan section 15, 2026-10-12).
        .iOS(.v15),
        .macOS(.v12),
    ],
    products: [
        // Swift apps add this product; it re-exports RubiconCore.
        .library(name: "Rubicon", targets: ["Rubicon"]),
        // Objective-C apps add this one as well (iOS Public API 1).
        .library(name: "RubiconObjC", targets: ["RubiconObjC"]),
    ],
    targets: [
        // Foundation only: no UIKit, no os.Logger, no Network (iOS Public API 8).
        .target(
            name: "RubiconCore",
            path: "Sources/RubiconCore",
            exclude: ["CLAUDE.md"]
        ),
        // iOS: factory, platform implementations, lifecycle, the privacy manifest (iOS Privacy 1).
        .target(
            name: "Rubicon",
            dependencies: ["RubiconCore"],
            path: "Sources/Rubicon",
            exclude: ["CLAUDE.md"],
            resources: [.process("PrivacyInfo.xcprivacy")]
        ),
        // The Objective-C wrapper: Swift files with @objc classes, RBN prefix.
        .target(
            name: "RubiconObjC",
            dependencies: ["Rubicon"],
            path: "Sources/RubiconObjC",
            exclude: ["CLAUDE.md"]
        ),
        // Shared test support; never a product.
        .target(
            name: "RubiconTesting",
            dependencies: ["RubiconCore"],
            path: "Sources/RubiconTesting"
        ),
        .testTarget(
            name: "RubiconCoreTests",
            dependencies: ["RubiconCore", "RubiconTesting"],
            path: "Tests/RubiconCoreTests",
            resources: [.copy("Fixtures")]
        ),
        .testTarget(
            name: "RubiconTests",
            dependencies: ["Rubicon", "RubiconTesting"],
            path: "Tests/RubiconTests"
        ),
        // Objective-C, XCTest, on the simulator (D16).
        .testTarget(
            name: "RubiconObjCTests",
            dependencies: ["RubiconObjC"],
            path: "Tests/RubiconObjCTests"
        ),
    ],
    swiftLanguageModes: [.v6]
)
