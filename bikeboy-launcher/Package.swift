// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "bikeboy-launcher",
    platforms: [
        .macOS(.v13)
    ],
    targets: [
        .executableTarget(
            name: "bikeboy-launcher",
            path: "Sources/bikeboy-launcher"
        )
    ]
)
