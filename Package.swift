// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "Fundus",
    defaultLocalization: "de",
    platforms: [.macOS("15.0")],
    targets: [
        .executableTarget(
            name: "Fundus",
            path: "Sources/Fundus"
        ),
        .testTarget(
            name: "FundusTests",
            dependencies: ["Fundus"],
            path: "Tests/FundusTests"
        ),
    ]
)
