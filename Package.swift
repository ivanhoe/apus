// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "Apus",
    platforms: [
        .iOS(.v16),
        .macOS(.v13)
    ],
    products: [
        .library(
            name: "Apus",
            targets: ["Apus"]
        ),
        .executable(
            name: "Demo",
            targets: ["Demo"]
        )
    ],
    dependencies: [],
    targets: [
        .target(
            name: "CHotReload",
            path: "Sources/CHotReload",
            publicHeadersPath: "include"
        ),
        .target(
            name: "Apus",
            dependencies: [
                "CHotReload"
            ]
        ),
        .executableTarget(
            name: "Demo",
            dependencies: ["Apus"]
        ),
        .testTarget(
            name: "ApusTests",
            dependencies: ["Apus"]
        )
    ]
)
