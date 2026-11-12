// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "TabletopCore",
    platforms: [.visionOS(.v1), .macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "TabletopCore", targets: ["TabletopCore"]),
    ],
    targets: [
        .target(name: "TabletopCore"),
        // Terminal simulation of bot-vs-bot hands; useful for exercising the engine without a headset.
        .executableTarget(name: "holdem-sim", dependencies: ["TabletopCore"]),
        .testTarget(name: "TabletopCoreTests", dependencies: ["TabletopCore"]),
    ]
)
