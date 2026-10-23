// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "VolumeControl",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "VolumeControl",
            path: "Sources/VolumeControl"
        )
    ]
)
