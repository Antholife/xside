// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "XSide",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "XSideCore", targets: ["XSideCore"]),
    ],
    targets: [
        .target(name: "XSideCore"),
        .testTarget(name: "XSideCoreTests", dependencies: ["XSideCore"]),
    ]
)
