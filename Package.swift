// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Bend",
    platforms: [.macOS("26.0")],
    products: [.executable(name: "Bend", targets: ["Browse"])],
    targets: [
        .target(name: "BrowseCore"),
        .target(name: "WebKitFindSupport"),
        .executableTarget(name: "Browse", dependencies: ["BrowseCore", "WebKitFindSupport"]),
        .testTarget(name: "BrowseCoreTests", dependencies: ["BrowseCore"]),
        .testTarget(name: "BrowseTests", dependencies: ["Browse"])
    ]
)
