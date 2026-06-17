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
                // chords-db (MIT, David Rubert 2016) — the guitar-voicing source. Decoded by
                // VoicingLibrary at runtime. The LICENSE text ships in-bundle so the consuming app
                // can surface it on its acknowledgements screen. Supersedes guitar_voicings.json.
                .process("Resources/chords_db_guitar.json"),
                .copy("Resources/chords_db_LICENSE.txt"),
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
