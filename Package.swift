// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SavageProtrackerPlayerApp",
    platforms: [
        .macOS(.v13),
        .iOS(.v16)
    ],
    products: [
        .executable(name: "SavageProtrackerPlayerApp", targets: ["SavageProtrackerPlayerApp"]),
        .library(name: "SavageProtrackerPlayerCore", targets: ["SavageProtrackerPlayerCore"])
    ],
    targets: [
        .target(
            name: "SavageProtrackerPlayerCore",
            dependencies: [],
            path: "Sources/SavageProtrackerPlayerCore"
        ),
        .executableTarget(
            name: "SavageProtrackerPlayerApp",
            dependencies: ["SavageProtrackerPlayerCore"],
            path: "Sources/SavageProtrackerPlayerApp"
        ),
        .testTarget(
            name: "SavageProtrackerPlayerTests",
            dependencies: ["SavageProtrackerPlayerCore"],
            path: "Tests/SavageProtrackerPlayerTests"
        )
    ]
)
