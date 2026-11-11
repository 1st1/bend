// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Bend",
    platforms: [.macOS("26.0")],
    products: [.executable(name: "Bend", targets: ["Browse"])],
    dependencies: [.package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.1")],
    targets: [
        .target(name: "BrowseCore"),
        .target(name: "WebKitFindSupport"),
        .executableTarget(name: "Browse", dependencies: ["BrowseCore", "WebKitFindSupport",
            .product(name: "Sparkle", package: "Sparkle")],
            linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]),
        .testTarget(name: "BrowseCoreTests", dependencies: ["BrowseCore"]),
        .testTarget(name: "BrowseTests", dependencies: ["Browse"])
    ]
)
