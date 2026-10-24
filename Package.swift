// swift-tools-version: 5.9
import PackageDescription

// The shared library intentionally excludes AppKit, SwiftUI, Keychain and external processes.
let package = Package(name: "PiliSharedCore",
    platforms: [.macOS(.v10_13), .iOS(.v14)],
    products: [.library(name: "PiliSharedCore", targets: ["PiliSharedCore"])],
    targets: [
        .target(name: "PiliSharedCore", path: "Sources", sources: ["Models.swift", "AdvancedOptions.swift", "Episodes.swift", "EpisodeBatches.swift", "SharedCore.swift"],
                swiftSettings: [.define("PILI_SHARED_CORE")]),
        .testTarget(name: "PiliSharedCoreTests", dependencies: ["PiliSharedCore"], path: "Tests/SharedCore")
    ])
