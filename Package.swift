// swift-tools-version: 6.0
import PackageDescription

// Die SwiftUI-App gibt es nur auf Apple-Plattformen. Package.swift läuft auf dem
// Host, deshalb blendet #if os(macOS) das App-Target unter Linux komplett aus —
// dort bleiben Core, CLI und Tests übrig. Ohne diesen Schalter versuchte
// `swift build` unter Linux SwiftUI zu importieren und scheiterte.
#if os(macOS)
let appProducts: [Product] = [
    .executable(name: "SavageModPlayerApp", targets: ["SavageModPlayerApp"])
]
let appTargets: [Target] = [
    .executableTarget(
        name: "SavageModPlayerApp",
        dependencies: ["SavageModPlayerCore"],
        path: "Sources/SavageModPlayerApp"
    )
]
#else
let appProducts: [Product] = []
let appTargets: [Target] = []
#endif

let package = Package(
    name: "SavageModPlayerApp",
    platforms: [
        .macOS(.v13),
        .iOS(.v16)
    ],
    products: appProducts + [
        .executable(name: "savage-cli", targets: ["SavageCLI"]),
        .library(name: "SavageModPlayerCore", targets: ["SavageModPlayerCore"])
    ],
    targets: appTargets + [
        .target(
            name: "SavageModPlayerCore",
            dependencies: [],
            path: "Sources/SavageModPlayerCore"
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
