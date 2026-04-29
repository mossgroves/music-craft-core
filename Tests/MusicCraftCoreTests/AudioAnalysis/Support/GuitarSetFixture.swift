import Foundation
import AVFoundation
import MusicCraftCore

/// GuitarSet fixture: audio file + parsed JAMS annotations.
struct GuitarSetFixture {
    let id: String  // e.g., "00_BN1-129-Eb_comp"
    let genre: Genre
    let audioURL: URL
    let parsed: ParsedGuitarSetData

    enum Genre: String {
        case bossaNova = "BN"
        case funk = "Funk"
        case rock = "Rock"
        case singerSongwriter = "SS"
    }

    /// Determine genre from fixture ID.
    /// ID format: "{player}_{genre}{details}_comp"
    /// e.g., "00_BN1-129-Eb_comp", "01_Funk1-119-A_comp"
    static func genreFromID(_ id: String) -> Genre {
        if id.contains("_BN") { return .bossaNova }
        if id.contains("_Funk") { return .funk }
        if id.contains("_Rock") { return .rock }
        if id.contains("_SS") { return .singerSongwriter }
        return .bossaNova  // fallback
    }

    /// Load all GuitarSet fixtures from the standard directory.
    static func all(in dir: URL? = nil) throws -> [GuitarSetFixture] {
        let directory = dir ?? fixtureDirectory()
        guard let directory = directory else {
            throw GuitarSetError.fixtureDirectoryNotFound
        }

        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: directory.path) else {
            throw GuitarSetError.fixtureDirectoryNotFound
        }

        // Discover all .wav files and pair with .jams
        let contents = try fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        )

        let wavFiles = contents.filter { $0.pathExtension == "wav" }
        var fixtures: [GuitarSetFixture] = []

        for wavURL in wavFiles.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let baseName = wavURL.deletingPathExtension().lastPathComponent

            // Look for corresponding .jams file
            let jamsURL = directory.appendingPathComponent(baseName).appendingPathExtension("jams")
            guard fileManager.fileExists(atPath: jamsURL.path) else {
                continue  // skip wav files without jams
            }

            do {
                let parsed = try JAMSParser.parse(url: jamsURL)
                let fixture = GuitarSetFixture(
                    id: baseName,
                    genre: genreFromID(baseName),
                    audioURL: wavURL,
                    parsed: parsed
                )
                fixtures.append(fixture)
            } catch {
                // Skip fixtures with parse errors
                print("Warning: Failed to parse JAMS for \(baseName): \(error)")
                continue
            }
        }

        return fixtures
    }

    /// Get the standard GuitarSet fixture directory.
    /// Mirrors the pattern from RealAudioChordTests.
    static func fixtureDirectory() -> URL? {
        // Try hardcoded standard path first
        let standardPath = URL(fileURLWithPath: "/Users/chris/Documents/Code/mossgroves-music-craft-core/Tests/MusicCraftCoreTests/AudioAnalysis/Fixtures/real-audio/guitarset")
        if FileManager.default.fileExists(atPath: standardPath.path) {
            return standardPath
        }

        // Fixtures are bundled in the test target
        let testBundle = Bundle.main

        // Try the standard fixture directory first
        if let fixturePath = testBundle.path(forResource: "Fixtures/real-audio/guitarset", ofType: nil) {
            return URL(fileURLWithPath: fixturePath)
        }

        // Fallback: check if running in Xcode or with xcodebuild (look for .build directory)
        if let buildPath = ProcessInfo.processInfo.environment["BUILD_DIR"],
           let projectPath = ProcessInfo.processInfo.environment["PROJECT_DIR"] {
            let possiblePath = URL(fileURLWithPath: projectPath)
                .appendingPathComponent("Tests/MusicCraftCoreTests/AudioAnalysis/Fixtures/real-audio/guitarset")
            if FileManager.default.fileExists(atPath: possiblePath.path) {
                return possiblePath
            }
        }

        return nil
    }

    /// Load audio samples from the fixture's WAV file.
    /// Returns [Float] PCM samples and sample rate.
    func loadAudio() throws -> (samples: [Float], sampleRate: Int) {
        let audioFile = try AVAudioFile(forReading: audioURL)
        let format = audioFile.processingFormat

        let sampleRate = Int(format.sampleRate)

        // Read entire file into buffer
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: UInt32(audioFile.length)) else {
            throw GuitarSetError.cannotAllocateAudioBuffer
        }

        try audioFile.read(into: buffer)

        // Extract samples from left channel (or mono)
        guard let floatChannelData = buffer.floatChannelData else {
            throw GuitarSetError.cannotReadAudioSamples
        }

        let frameLength = Int(buffer.frameLength)
        let samples = Array(UnsafeBufferPointer(start: floatChannelData[0], count: frameLength))

        return (samples: samples, sampleRate: sampleRate)
    }
}

enum GuitarSetError: Error {
    case fixtureDirectoryNotFound
    case cannotReadAudioFormat
    case cannotAllocateAudioBuffer
    case cannotReadAudioSamples
}
