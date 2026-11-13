// swift-tools-version: 6.2
import PackageDescription

var targets: [Target] = [
    .target(name: "SandbarCore"),
    .testTarget(name: "SandbarCoreTests", dependencies: ["SandbarCore"]),
]

let package = Package(
    name: "Sandbar",
    platforms: [.macOS(.v14)],
    targets: targets,
    swiftLanguageModes: [.v6]
)
