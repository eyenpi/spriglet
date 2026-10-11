// swift-tools-version: 6.2
import PackageDescription
let package = Package(name: "IntakeExtraction", platforms: [.macOS(.v26)],
    dependencies: [.package(path: "../../Packages/CompanionKit")],
    targets: [
        .target(name: "IntakeExtraction", dependencies: [.product(name: "CompanionCore", package: "CompanionKit")], path: "Sources"),
        .testTarget(name: "IntakeExtractionTests", dependencies: ["IntakeExtraction"], path: "Tests", resources: [.copy("Fixtures")])
    ], swiftLanguageModes: [.v6])
