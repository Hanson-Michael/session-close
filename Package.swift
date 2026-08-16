// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "SessionClose",
    platforms: [
        .macOS(.v13) // Table view (used in ContentView) requires macOS 13+
    ],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.0.0")
    ],
    targets: [
        .executableTarget(
            name: "SessionClose",
            dependencies: [
                .product(name: "Sparkle", package: "Sparkle")
            ],
            path: "Sources/SessionClose"
        )
    ]
)
