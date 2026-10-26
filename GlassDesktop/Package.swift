// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "GlassDesktop",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "GlassDesktop", targets: ["GlassDesktop"])
    ],
    targets: [
        .target(name: "GlassDesktopCore"),
        .executableTarget(name: "GlassDesktop", dependencies: ["GlassDesktopCore"]),
        .testTarget(name: "GlassDesktopCoreTests", dependencies: ["GlassDesktopCore"])
    ]
)
