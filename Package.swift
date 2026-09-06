// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "Pip",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "PipDomain", targets: ["PipDomain"]),
        .library(name: "PipActions", targets: ["PipActions"]),
        .library(name: "PipPersistence", targets: ["PipPersistence"]),
        .library(name: "PipEngineAdapter", targets: ["PipEngineAdapter"]),
        .library(name: "PipUI", targets: ["PipUI"]),
        .executable(name: "Pip", targets: ["PipApp"])
    ],
    targets: [
        .target(name: "PipDomain"),
        .target(
            name: "PipActions",
            dependencies: ["PipDomain"],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("ApplicationServices")
            ]
        ),
        .target(
            name: "PipPersistence",
            dependencies: ["PipDomain"]
        ),
        .target(
            name: "PipEngineAdapter",
            dependencies: ["PipDomain"],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("IOKit")
            ]
        ),
        .target(
            name: "PipUI",
            dependencies: [
                "PipDomain",
                "PipActions",
                "PipPersistence",
                "PipEngineAdapter"
            ],
            linkerSettings: [
                .linkedFramework("SwiftUI"),
                .linkedFramework("AppKit"),
                .linkedFramework("ApplicationServices"),
                .linkedFramework("ServiceManagement"),
                .linkedFramework("Carbon")
            ]
        ),
        .executableTarget(
            name: "PipApp",
            dependencies: [
                "PipUI",
                "PipDomain",
                "PipActions",
                "PipPersistence",
                "PipEngineAdapter"
            ],
            swiftSettings: [
                .unsafeFlags(["-parse-as-library"])
            ]
        )
    ]
)

// Build Apple Silicon with: swift build --arch arm64
// SwiftPM does not produce a signed .app bundle. Verify TCC, login launch,
// menu-bar rendering, sensor access, and media-key delivery in the packaged app.
// Preserve any vendored engine targets/resources from the core package when
// merging this manifest; none were identified in the supplied public API.
