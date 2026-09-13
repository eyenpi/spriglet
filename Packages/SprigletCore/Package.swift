// swift-tools-version: 6.3

import PackageDescription

let package = Package(
    name: "SprigletCore",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "SprigletCore", targets: ["SprigletCore"])
    ],
    targets: [
        .target(name: "SprigletCore"),
        .testTarget(name: "SprigletCoreTests", dependencies: ["SprigletCore"])
    ]
)
