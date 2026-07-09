// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SavageModPlayerApp",
    platforms: [
        .macOS(.v13),
        .iOS(.v16)
    ],
    products: [
        .executable(name: "SavageModPlayerApp", targets: ["SavageModPlayerApp"]),
        .executable(name: "savage-cli", targets: ["SavageCLI"]),
        .library(name: "SavageModPlayerCore", targets: ["SavageModPlayerCore"])
    ],
    targets: [
        .target(
            name: "SavageModPlayerCore",
            dependencies: [],
            path: "Sources/SavageModPlayerCore"
        ),
        .executableTarget(
            name: "SavageModPlayerApp",
            dependencies: ["SavageModPlayerCore"],
            path: "Sources/SavageModPlayerApp"
        ),
        // Kopfloser CLI-Renderer (headless Tests + Linux-Port-Fundament).
        .executableTarget(
            name: "SavageCLI",
            dependencies: ["SavageModPlayerCore"],
            path: "Sources/SavageCLI"
        ),
        .testTarget(
            name: "SavageModPlayerTests",
            dependencies: ["SavageModPlayerCore"],
            path: "Tests/SavageModPlayerTests"
        )
    ]
)
