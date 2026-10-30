// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "XSide",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "XSideCore", targets: ["XSideCore"]),
        .executable(name: "XSideApp", targets: ["XSideApp"]),
    ],
    targets: [
        .target(name: "XSideCore"),
        .executableTarget(name: "XSideApp", dependencies: ["XSideCore"]),
        .testTarget(name: "XSideCoreTests", dependencies: ["XSideCore"], exclude: ["Fixtures"]),
    ]
)
