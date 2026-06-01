// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "MusicCraftCore",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [.library(name: "MusicCraftCore", targets: ["MusicCraftCore"])],
    dependencies: [],
    targets: [
        .target(
            name: "MusicCraftCore",
            resources: [
                .process("Resources/guitar_voicings.json"),
                .process("Resources/music_theory.json"),
                // .copy (not .process) so the Core ML .mlpackage directory is preserved
                // verbatim in the bundle; .process flattens it and breaks Bundle.module lookup.
                .copy("Resources/nmp.mlpackage"),
            ]
        ),
        .testTarget(
            name: "MusicCraftCoreTests",
            dependencies: ["MusicCraftCore"],
            resources: [.copy("AudioAnalysis/Fixtures")]
        )
    ]
)
