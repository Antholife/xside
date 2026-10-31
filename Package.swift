// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "XSide",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "XSideCore", targets: ["XSideCore"]),
        .executable(name: "XSideApp", targets: ["XSideApp"]),
    ],
    dependencies: [
        // Self-updates (see scripts/release.sh). Pinned: an update changes how updates install.
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.1"),
    ],
    targets: [
        .target(name: "XSideCore"),
        .executableTarget(name: "XSideApp", dependencies: [
            "XSideCore",
            .product(name: "Sparkle", package: "Sparkle"),
        ]),
        .testTarget(name: "XSideCoreTests", dependencies: ["XSideCore"], exclude: ["Fixtures"]),
    ]
)
