// swift-tools-version: 6.4
import PackageDescription

let package = Package(
    name: "SkaldPlatform27",
    platforms: [.macOS(.v27)],
    products: [
        .library(name: "SkaldPlatform27", targets: ["SkaldPlatform27"]),
    ],
    dependencies: [
        .package(path: "../SkaldCore"),
    ],
    targets: [
        .target(name: "SkaldPlatform27", dependencies: [.product(name: "SkaldCore", package: "SkaldCore")]),
        .executableTarget(name: "skald-eval", dependencies: [
            "SkaldPlatform27",
            .product(name: "SkaldCore", package: "SkaldCore"),
        ]),
        .testTarget(name: "SkaldPlatform27Tests", dependencies: [
            "SkaldPlatform27",
            .product(name: "SkaldCore", package: "SkaldCore"),
        ]),
    ]
)
