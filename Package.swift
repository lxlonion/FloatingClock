// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "FloatingClock",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "FloatingClock", targets: ["FloatingClock"])],
    targets: [
        .target(name: "ClockCore"),
        .executableTarget(name: "FloatingClock", dependencies: ["ClockCore"]),
        .testTarget(name: "ClockCoreTests", dependencies: ["ClockCore"])
    ]
)
