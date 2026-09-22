// swift-tools-version: 6.3

import PackageDescription

let package = Package(
    name: "SprigletCore",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "SprigletCore", targets: ["SprigletCore"]),
        .library(name: "SprigletIntelligence", targets: ["SprigletIntelligence"])
    ],
    targets: [
        .target(name: "SprigletCore"),
        .target(name: "SprigletIntelligence"),
        .testTarget(name: "SprigletCoreTests", dependencies: ["SprigletCore"]),
        .testTarget(name: "SprigletIntelligenceTests", dependencies: ["SprigletIntelligence"])
    ]
)
