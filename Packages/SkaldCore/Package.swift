// swift-tools-version: 6.4
import PackageDescription

let package = Package(
    name: "SkaldCore",
    platforms: [.macOS(.v27)],
    products: [
        .library(name: "SkaldCore", targets: ["SkaldCore"]),
    ],
    targets: [
        .target(name: "SkaldCore"),
        .testTarget(
            name: "SkaldCoreTests",
            dependencies: ["SkaldCore"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
