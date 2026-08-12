// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "DevSweep",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "DevSweep", targets: ["DevSweep"]),
        .executable(name: "DevSweepUpdater", targets: ["DevSweepUpdater"])
    ],
    targets: [
        .executableTarget(
            name: "DevSweep",
            path: "Sources/DevSweep"
        ),
        .executableTarget(
            name: "DevSweepUpdater",
            path: "Sources/DevSweepUpdater"
        ),
        .testTarget(
            name: "DevSweepTests",
            dependencies: ["DevSweep"],
            path: "Tests/DevSweepTests"
        )
    ],
    swiftLanguageModes: [.v5]
)
