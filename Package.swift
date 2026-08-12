// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Sift",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "Sift", targets: ["Sift"]),
        .executable(name: "SiftUpdater", targets: ["SiftUpdater"])
    ],
    targets: [
        .executableTarget(
            name: "Sift",
            path: "Sources/Sift"
        ),
        .executableTarget(
            name: "SiftUpdater",
            path: "Sources/SiftUpdater"
        ),
        .testTarget(
            name: "SiftTests",
            dependencies: ["Sift"],
            path: "Tests/SiftTests"
        )
    ],
    swiftLanguageModes: [.v5]
)
