// swift-tools-version: 6.4
import PackageDescription

let package = Package(
    name: "SkaldCore",
    platforms: [.macOS(.v27)],
    products: [
        .library(name: "SkaldCore", targets: ["SkaldCore"]),
        .library(name: "SkaldCoreTestSupport", targets: ["SkaldCoreTestSupport"]),
    ],
    targets: [
        .target(name: "SkaldCore"),
        .target(
            name: "SkaldCoreTestSupport",
            dependencies: ["SkaldCore"],
            resources: [.copy("Fixtures")]
        ),
        .testTarget(
            name: "SkaldCoreTests",
            dependencies: ["SkaldCore", "SkaldCoreTestSupport"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
