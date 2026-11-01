// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "LiveWall",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "LiveWall",
            path: "Sources/LiveWall"
        )
    ]
)
