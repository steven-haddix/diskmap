// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "DiskMap",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "DiskMap", targets: ["DiskMap"]),
        .library(name: "DiskMapCore", targets: ["DiskMapCore"]),
    ],
    targets: [
        .target(name: "DiskMapCore"),
        .executableTarget(name: "DiskMap", dependencies: ["DiskMapCore"]),
        .testTarget(name: "DiskMapCoreTests", dependencies: ["DiskMapCore"]),
    ]
)
