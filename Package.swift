// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "MusicCraftCore",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [.library(name: "MusicCraftCore", targets: ["MusicCraftCore"])],
    dependencies: [
        // WhisperKit (Argmax, MIT) — CoreML Whisper runtime for the Voice/WhisperLyricsEngine
        // sung-lyric transcription path (Sanctuary BACKLOG "Lyric transcription", GO 2026-08-07).
        // Pinned EXACT at 1.1.0: the pinned decode config in WhisperLyricsEngine was measured
        // against this tag's decode behavior; a silent minor bump could shift WER.
        .package(url: "https://github.com/argmaxinc/WhisperKit", exact: "1.1.0"),
    ],
    targets: [
        .target(
            name: "MusicCraftCore",
            dependencies: [
                .product(name: "WhisperKit", package: "WhisperKit"),
            ],
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
