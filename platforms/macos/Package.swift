// swift-tools-version: 5.10
import Foundation
import PackageDescription

let packageDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
let repoRoot = packageDir.deletingLastPathComponent().deletingLastPathComponent().path

let package = Package(
    name: "KoeMacHost",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .executable(name: "Koe", targets: ["Koe"]),
    ],
    dependencies: [
        .package(path: "../apple-shared"),
    ],
    targets: [
        .executableTarget(
            name: "Koe",
            dependencies: [
                .product(name: "KoeAppleShared", package: "apple-shared"),
            ],
            path: "Sources/Koe",
            linkerSettings: [
                .unsafeFlags(["-L\(repoRoot)/target/debug"], .when(configuration: .debug)),
                .unsafeFlags(["-L\(repoRoot)/target/release"], .when(configuration: .release)),
                .linkedLibrary("koe_host_api"),
                .linkedLibrary("c++"),
                .linkedFramework("Accelerate"),
                .linkedFramework("AppKit"),
                .linkedFramework("CoreBluetooth"),
                .linkedFramework("SwiftUI"),
            ]
        ),
        .testTarget(
            name: "KoeMacHostTests",
            dependencies: [
                "Koe",
                .product(name: "KoeAppleShared", package: "apple-shared"),
            ],
            path: "Tests/KoeMacHostTests",
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
