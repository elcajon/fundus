// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "Ablage",
    defaultLocalization: "de",
    platforms: [.macOS("15.0")],
    targets: [
        .executableTarget(
            name: "Ablage",
            path: "Sources/Ablage"
        ),
        .testTarget(
            name: "AblageTests",
            dependencies: ["Ablage"],
            path: "Tests/AblageTests"
        ),
    ]
)
