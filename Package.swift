// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "shutlid",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "ShutlidCore"),
        .executableTarget(name: "shutlid", dependencies: ["ShutlidCore"]),
        .executableTarget(name: "ShutlidApp", dependencies: ["ShutlidCore"]),
        .testTarget(name: "ShutlidCoreTests", dependencies: ["ShutlidCore"]),
    ]
)
