// swift-tools-version: 5.9
import PackageDescription

// Only the portable grouping engine is compiled from Vendor. Sensor capture and
// permission APIs are deliberately not linked into this milestone.
var engineSources = ["Sources/PipEngineAdapter"]
var engineExcludes = [
    "Resources", "Tests",
    "Sources/PipDomain", "Sources/PipActions",
    "Sources/PipPersistence", "Sources/PipApp"
]
#if os(macOS)
engineSources.append("Vendor/Bump/Core/GestureEngine/GestureEngine.swift")
#else
engineExcludes.append("Vendor")
#endif

let package = Package(
    name: "Pip",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "PipDomain", targets: ["PipDomain"]),
        .library(name: "PipActions", targets: ["PipActions"]),
        .library(name: "PipPersistence", targets: ["PipPersistence"]),
        .library(name: "PipEngineAdapter", targets: ["PipEngineAdapter"]),
        .executable(name: "PipApp", targets: ["PipApp"])
    ],
    targets: [
        .target(name: "PipDomain"),
        .target(name: "PipActions", dependencies: ["PipDomain"]),
        .target(
            name: "PipPersistence",
            dependencies: ["PipDomain"],
            path: ".",
            exclude: [
                "Vendor", "Tests", "Sources/PipDomain", "Sources/PipActions",
                "Sources/PipEngineAdapter", "Sources/PipApp"
            ],
            sources: ["Sources/PipPersistence"],
            resources: [.copy("Resources/Presets")]
        ),
        .target(
            name: "PipEngineAdapter",
            dependencies: ["PipDomain"],
            path: ".",
            exclude: engineExcludes,
            sources: engineSources
        ),
        .executableTarget(
            name: "PipApp",
            dependencies: [
                "PipDomain", "PipActions", "PipPersistence", "PipEngineAdapter"
            ]
        ),
        .testTarget(name: "PipDomainTests", dependencies: ["PipDomain"]),
        .testTarget(name: "PipActionsTests", dependencies: ["PipActions", "PipDomain"]),
        .testTarget(
            name: "PipPersistenceTests",
            dependencies: ["PipPersistence", "PipDomain"]
        ),
        .testTarget(
            name: "PipEngineAdapterTests",
            dependencies: ["PipEngineAdapter", "PipDomain"]
        )
    ],
    swiftLanguageVersions: [.v5]
)
