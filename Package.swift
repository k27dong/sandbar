// swift-tools-version: 6.2
import PackageDescription

var targets: [Target] = [
    .target(name: "SandbarCore"),
    .target(name: "SandbarTestSupport", path: "Tests/Support"),
    .testTarget(name: "SandbarCoreTests", dependencies: ["SandbarCore", "SandbarTestSupport"]),
]

#if os(macOS)
    let onMainActor: [SwiftSetting] = [.defaultIsolation(MainActor.self)]
    targets += [
        .target(name: "SandbarUI", dependencies: ["SandbarCore"], exclude: ["Resources"], swiftSettings: onMainActor),
        .executableTarget(name: "Sandbar", dependencies: ["SandbarUI"], swiftSettings: onMainActor),
        .testTarget(
            name: "SandbarUITests", dependencies: ["SandbarUI", "SandbarTestSupport"], swiftSettings: onMainActor),
    ]
#endif

let package = Package(
    name: "Sandbar",
    platforms: [.macOS(.v14)],
    targets: targets,
    swiftLanguageModes: [.v6]
)
