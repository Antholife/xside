// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "XSide",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "XSideCore", targets: ["XSideCore"]),
        .executable(name: "XSideApp", targets: ["XSideApp"]),
        // The `xside` command line tool, shipped inside XSide.app (Contents/Helpers/xside).
        .executable(name: "xside", targets: ["XSideCLI"]),
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
        .executableTarget(name: "XSideCLI", dependencies: ["XSideCore"]),
        .testTarget(name: "XSideCoreTests", dependencies: ["XSideCore"], exclude: ["Fixtures"]),
    ]
)
