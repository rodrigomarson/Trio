// swift-tools-version: 5.7

import PackageDescription

let package = Package(
    name: "MicroTechCGMKit",
    platforms: [
        .iOS("17.0"),
        .macOS(.v13)
    ],
    products: [
        .library(
            name: "MicroTechCGMKit",
            targets: ["MicroTechCGMKit"]
        ),
        .executable(
            name: "MicroTechDiscoveryProbe",
            targets: ["MicroTechDiscoveryProbe"]
        )
    ],
    dependencies: [
        .package(
            url: "https://github.com/krzyzanowskim/CryptoSwift",
            exact: "1.10.0"
        )
    ],
    targets: [
        .target(
            name: "MicroTechCGMKit",
            dependencies: ["CryptoSwift"]
        ),
        .executableTarget(
            name: "MicroTechDiscoveryProbe",
            dependencies: ["MicroTechCGMKit"]
        ),
        .testTarget(
            name: "MicroTechCGMKitTests",
            dependencies: ["MicroTechCGMKit"]
        )
    ]
)
