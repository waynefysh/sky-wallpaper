// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "SkyWallpaper",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "SkyCore", targets: ["SkyCore"]),
        .executable(name: "SkyWallpaper", targets: ["SkyWallpaper"]),
    ],
    targets: [
        // Pure Swift astronomy + weather model. No UI code, so it is testable anywhere.
        .target(
            name: "SkyCore",
            resources: [.process("Resources")]
        ),
        // The macOS menu bar app that draws the sky behind the desktop icons.
        .executableTarget(
            name: "SkyWallpaper",
            dependencies: ["SkyCore"]
        ),
        .testTarget(
            name: "SkyCoreTests",
            dependencies: ["SkyCore"]
        ),
    ]
)
