// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Bend",
    platforms: [.macOS("26.0")],
    products: [.executable(name: "Bend", targets: ["Browse"]), .library(name: "AI", targets: ["AI"]),
               .executable(name: "agent-example", targets: ["AgentExample"])],
    dependencies: [.package(url: "https://github.com/mgriebling/SwiftMath.git", exact: "1.7.3"), .package(url: "https://github.com/swiftlang/swift-markdown.git", exact: "0.9.0"), .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.1")],
    targets: [
        .target(name: "AI"),
        .executableTarget(name: "AgentExample", dependencies: ["AI"]),
        .testTarget(name: "AITests", dependencies: ["AI"]),
        .target(name: "BrowseCore"),
        .target(name: "WebKitFindSupport"),
        .executableTarget(name: "Browse", dependencies: ["BrowseCore", "WebKitFindSupport", .product(name: "SwiftMath", package: "SwiftMath"),
            .product(name: "Sparkle", package: "Sparkle"), "AI", .product(name: "Markdown", package: "swift-markdown")],
            linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]),
        .testTarget(name: "BrowseCoreTests", dependencies: ["BrowseCore"]),
        .testTarget(name: "BrowseTests", dependencies: ["Browse"])
    ]
)
