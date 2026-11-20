// swift-tools-version: 5.10
import Foundation
import PackageDescription

let packageDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
let repoRoot = packageDir.deletingLastPathComponent().deletingLastPathComponent().path

let hostApiLinkerSettings: [LinkerSetting] = [
    .unsafeFlags(["-L\(repoRoot)/target/debug"], .when(configuration: .debug)),
    .unsafeFlags(["-L\(repoRoot)/target/release"], .when(configuration: .release)),
    .linkedLibrary("koe_host_api"),
    .linkedLibrary("c++"),
    .linkedFramework("Accelerate"),
]

let package = Package(
    name: "KoeAppleShared",
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
            name: "KoeAppleShared",
            targets: ["KoeAppleShared"]
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
            path: "Sources/KoeAppleCore"
        ),
        .target(
            name: "KoeAppleShared",
            dependencies: ["KoeAppleCore"],
            path: "Sources/KoeAppleShared"
        ),
        .testTarget(
            name: "KoeAppleCoreTests",
            dependencies: ["KoeAppleCore", "CKoeHostApi"],
            path: "Tests/KoeAppleCoreTests",
            linkerSettings: hostApiLinkerSettings
        ),
        .testTarget(
            name: "KoeAppleSharedTests",
            dependencies: ["KoeAppleShared", "KoeAppleCore", "CKoeHostApi"],
            path: "Tests/KoeAppleSharedTests",
            linkerSettings: hostApiLinkerSettings
        ),
    ]
)
