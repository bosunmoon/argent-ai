// swift-tools-version: 5.7

import PackageDescription

let package = Package(
    name: "argent-vision",
    platforms: [
        .macOS(.v11)
    ],
    products: [
        .executable(name: "argent-vision", targets: ["argent-vision"]),
        .executable(name: "argent-vision-diagnostics", targets: ["argent-vision-diagnostics"])
    ],
    targets: [
        .executableTarget(name: "argent-vision"),
        .executableTarget(name: "argent-vision-diagnostics")
    ]
)
