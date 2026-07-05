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
        .testTarget(
            name: "SavageModPlayerTests",
            dependencies: ["SavageModPlayerCore"],
            path: "Tests/SavageModPlayerTests"
        )
    ]
)
