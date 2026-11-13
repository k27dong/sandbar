// swift-tools-version: 6.2
import PackageDescription

var products: [Product] = []
var targets: [Target] = [
    .target(name: "SandbarCore"),
    .target(name: "SandbarTestSupport", path: "Tests/Support"),
    .testTarget(name: "SandbarCoreTests", dependencies: ["SandbarCore", "SandbarTestSupport"]),
]

#if os(macOS)
    let onMainActor: [SwiftSetting] = [.defaultIsolation(MainActor.self)]
    products += [.library(name: "SandbarUI", targets: ["SandbarUI"])]
    targets += [
        .target(name: "SandbarUI", dependencies: ["SandbarCore"], swiftSettings: onMainActor),
        .testTarget(
            name: "SandbarUITests", dependencies: ["SandbarUI", "SandbarTestSupport"], swiftSettings: onMainActor),
    ]
#endif

let package = Package(
    name: "Sandbar",
    platforms: [.macOS(.v14)],
    products: products,
    targets: targets,
    swiftLanguageModes: [.v6]
)
