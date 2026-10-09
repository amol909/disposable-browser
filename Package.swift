// swift-tools-version: 5.9
import PackageDescription

var products: [Product] = [.library(name: "BrowserCore", targets: ["BrowserCore"])]
var dependencies: [Package.Dependency] = []
var targets: [Target] = [
    .target(name: "BrowserCore"),
    .testTarget(name: "BrowserCoreTests", dependencies: ["BrowserCore"])
]

#if os(macOS)
products.append(.executable(name: "Meerkat", targets: ["Meerkat"]))
dependencies.append(.package(url: "https://github.com/sindresorhus/KeyboardShortcuts", exact: "3.1.0"))
targets.append(.executableTarget(name: "Meerkat", dependencies: [
    "BrowserCore",
    .product(name: "KeyboardShortcuts", package: "KeyboardShortcuts")
]))
targets.append(.testTarget(name: "MeerkatTests", dependencies: ["Meerkat"]))
#endif

let package = Package(
    name: "Meerkat",
    platforms: [.macOS(.v14)],
    products: products,
    dependencies: dependencies,
    targets: targets
)
