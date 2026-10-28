// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "XSide",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "XSideCore", targets: ["XSideCore"]),
        .executable(name: "XSideApp", targets: ["XSideApp"]),
        .executable(name: "XSideWakeHelper", targets: ["XSideWakeHelper"]),
    ],
    targets: [
        .target(name: "XSideCore"),
        .target(name: "XSideWakeProtocol"),
        .executableTarget(name: "XSideApp", dependencies: ["XSideCore", "XSideWakeProtocol"]),
        .executableTarget(name: "XSideWakeHelper", dependencies: ["XSideWakeProtocol"]),
        .testTarget(name: "XSideCoreTests", dependencies: ["XSideCore"]),
    ]
)
