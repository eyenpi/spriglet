// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "CompanionKit",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "CompanionCore", targets: ["CompanionCore"]),
        .library(name: "CompanionRendering", targets: ["CompanionRendering"]),
        .executable(name: "companion-preview", targets: ["CompanionPreview"]),
    ],
    targets: [
        .target(name: "CompanionCore"),
        .target(name: "CompanionRendering", dependencies: ["CompanionCore"]),
        .executableTarget(name: "CompanionPreview", dependencies: ["CompanionCore", "CompanionRendering"]),
        .testTarget(name: "CompanionCoreTests", dependencies: ["CompanionCore"]),
        .testTarget(name: "CompanionRenderingTests", dependencies: ["CompanionRendering", "CompanionCore"]),
    ],
    swiftLanguageModes: [.v6]
)
