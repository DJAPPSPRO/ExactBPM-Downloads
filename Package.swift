// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "RhythmCoreAutoCue",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "RhythmCoreAutoCue", targets: ["RhythmCoreAutoCue"]),
        .executable(name: "autocue-cli", targets: ["autocue-cli"]),
        .executable(name: "autocue-worker", targets: ["autocue-worker"]),
    ],
    targets: [
        .target(name: "AutoCueCore", path: "Sources/AutoCueCore"),
        .executableTarget(name: "RhythmCoreAutoCue", dependencies: ["AutoCueCore"], path: "Sources/RhythmCoreAutoCue"),
        .executableTarget(name: "autocue-cli", dependencies: ["AutoCueCore"], path: "Sources/autocue-cli"),
        .executableTarget(name: "autocue-worker", dependencies: ["AutoCueCore"], path: "Sources/autocue-worker"),
        .testTarget(name: "AutoCueCoreTests", dependencies: ["AutoCueCore"], path: "Tests/AutoCueCoreTests"),
    ]
)
