// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "BocchiDB",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
    ],
    products: [
        .library(name: "BocchiDB", targets: ["BocchiDB"]),
    ],
    targets: [
        .target(name: "BocchiDB"),
        .testTarget(name: "BocchiDBTests", dependencies: ["BocchiDB"]),
    ]
)
