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
            linkerSettings: hostApiLinkerSettings + [
                .linkedFramework("AppKit"),
                .linkedFramework("CoreBluetooth"),
                .linkedFramework("SwiftUI"),
            ]
        ),
        .testTarget(
            name: "KoeMacHostTests",
            dependencies: [
                "Koe",
                .product(name: "KoeAppleCore", package: "apple-shared"),
                .product(name: "KoeAppleShared", package: "apple-shared"),
            ],
            path: "Tests/KoeMacHostTests",
            linkerSettings: hostApiLinkerSettings
        ),
    ]
)
