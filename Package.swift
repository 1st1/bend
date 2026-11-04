// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Browse",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "Browse", targets: ["Browse"])],
    targets: [
        .target(name: "BrowseCore"),
        .executableTarget(name: "Browse", dependencies: ["BrowseCore"]),
        .testTarget(name: "BrowseCoreTests", dependencies: ["BrowseCore"]),
        .testTarget(name: "BrowseTests", dependencies: ["Browse"])
    ]
)
