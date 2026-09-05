// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Bump",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Bump",
            path: "Sources/Bump"
        )
    ]
)
