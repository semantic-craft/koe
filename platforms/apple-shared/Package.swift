// swift-tools-version: 5.10
import Foundation
import PackageDescription

let packageDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
let repoRoot = packageDir.deletingLastPathComponent().deletingLastPathComponent().path

let hostApiLinkerSettings: [LinkerSetting] = [
    .unsafeFlags(["\(repoRoot)/target/debug/libkoe_host_api.a"], .when(configuration: .debug)),
    .unsafeFlags(["\(repoRoot)/target/release/libkoe_host_api.a"], .when(configuration: .release)),
    .linkedLibrary("c++"),
    .linkedFramework("Accelerate"),
]

let strictConcurrencySettings: [SwiftSetting] = [
    .enableExperimentalFeature("StrictConcurrency"),
]

let package = Package(
    name: "KoeApple",
    platforms: [
        .macOS(.v14),
        .iOS(.v17),
    ],
    products: [
        .library(
            name: "KoeAppleCore",
            targets: ["KoeAppleCore"]
        ),
        .library(
            name: "KoeMacUI",
            targets: ["KoeMacUI"]
        ),
    ],
    targets: [
        .target(
            name: "CKoeHostApi",
            path: "Sources/CKoeHostApi",
            publicHeadersPath: "include"
        ),
        .target(
            name: "KoeAppleCore",
            dependencies: ["CKoeHostApi"],
            path: "Sources/KoeAppleCore",
            swiftSettings: strictConcurrencySettings
        ),
        .target(
            name: "KoeMacUI",
            dependencies: ["KoeAppleCore"],
            path: "Sources/KoeMacUI",
            swiftSettings: strictConcurrencySettings
        ),
        .testTarget(
            name: "KoeAppleCoreTests",
            dependencies: ["KoeAppleCore", "CKoeHostApi"],
            path: "Tests/KoeAppleCoreTests",
            swiftSettings: strictConcurrencySettings,
            linkerSettings: hostApiLinkerSettings
        ),
        .testTarget(
            name: "KoeMacUITests",
            dependencies: ["KoeMacUI", "KoeAppleCore", "CKoeHostApi"],
            path: "Tests/KoeMacUITests",
            swiftSettings: strictConcurrencySettings,
            linkerSettings: hostApiLinkerSettings
        ),
    ]
)
