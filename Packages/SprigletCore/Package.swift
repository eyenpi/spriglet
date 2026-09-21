// swift-tools-version: 6.3

import PackageDescription

let package = Package(
    name: "SprigletCore",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "SprigletCore", targets: ["SprigletCore"]),
        .library(name: "SprigletConversation", targets: ["SprigletConversation"])
    ],
    targets: [
        .target(name: "SprigletCore"),
        .target(name: "SprigletConversation", dependencies: ["SprigletCore"]),
        .testTarget(name: "SprigletCoreTests", dependencies: ["SprigletCore"]),
        .testTarget(name: "SprigletConversationTests", dependencies: ["SprigletConversation"])
    ]
)
