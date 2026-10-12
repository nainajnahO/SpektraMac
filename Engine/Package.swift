// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "SpektraEngine",
    platforms: [.macOS("26.5")],
    products: [
        .library(name: "SpektraEngine", targets: ["SpektraEngine"]),
        .executable(name: "spektra-cli", targets: ["spektra-cli"]),
    ],
    targets: [
        .target(name: "SpektraEngine", resources: [.copy("Resources")]),
        .executableTarget(name: "spektra-cli", dependencies: ["SpektraEngine"]),
        .testTarget(name: "SpektraEngineTests", dependencies: ["SpektraEngine"]),
    ]
)
