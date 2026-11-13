// swift-tools-version: 5.10
import Foundation
import PackageDescription

let packageDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
let repoRoot = packageDir.deletingLastPathComponent().deletingLastPathComponent().path

let package = Package(
    name: "KoeAppleShared",
    platforms: [
        .macOS(.v14),
        .iOS(.v17),
    ],
    products: [
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
            name: "KoeAppleShared",
            dependencies: ["CKoeHostApi"],
            path: "Sources/KoeAppleShared"
        ),
        .testTarget(
            name: "KoeAppleSharedTests",
            dependencies: ["KoeAppleShared"],
            path: "Tests/KoeAppleSharedTests",
            linkerSettings: [
                .unsafeFlags(["-L\(repoRoot)/target/debug"], .when(configuration: .debug)),
                .unsafeFlags(["-L\(repoRoot)/target/release"], .when(configuration: .release)),
                .linkedLibrary("koe_host_api"),
                .linkedLibrary("c++"),
                .linkedFramework("Accelerate"),
            ]
        ),
    ]
)
