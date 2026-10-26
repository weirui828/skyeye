// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "SkyEye",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "SkyEyeCore"),
        .executableTarget(name: "SkyEyeApp", dependencies: ["SkyEyeCore"]),
        .executableTarget(name: "sky", dependencies: ["SkyEyeCore"]),
        .executableTarget(name: "skyeye-mcp", dependencies: ["SkyEyeCore"]),
        .executableTarget(name: "skyeye-logwriter", dependencies: ["SkyEyeCore"]),
        .testTarget(name: "SkyEyeCoreTests", dependencies: ["SkyEyeCore"]),
    ]
)
