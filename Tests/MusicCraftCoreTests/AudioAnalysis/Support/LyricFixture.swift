import Foundation
import AVFoundation
@testable import MusicCraftCore

/// TTS-generated lyric fixture for Phase 5 LyricsExtractor baseline testing.
struct LyricFixture {
    let id: String
    let category: Category
    let audioURL: URL
    let words: [GroundTruth.WordAnnotation]

    enum Category: String {
        case baseline
        case pangram
        case phonetic
        case songlike
        case homophone
        case numbers
        case longPassage
    }

    /// Load audio samples from WAV file.
    func loadAudio() throws -> (samples: [Float], sampleRate: Double) {
        let audioFile = try AVAudioFile(forReading: audioURL)
        let format = audioFile.processingFormat

        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(audioFile.length)) else {
            throw NSError(domain: "Audio", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to create audio buffer"])
        }

        try audioFile.read(into: buffer)

        guard let floatChannelData = buffer.floatChannelData else {
            throw NSError(domain: "Audio", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to read float channel data"])
        }

        let frameLength = Int(buffer.frameLength)
        let samples = Array(UnsafeBufferPointer(start: floatChannelData[0], count: frameLength))
        let sampleRate = format.sampleRate

        return (samples, sampleRate)
    }

    /// Load all TTS fixtures from the fixture directory.
    static func all() throws -> [LyricFixture] {
        guard let fixtureDir = fixtureDirectory() else {
            return []
        }

        let fileManager = FileManager.default
        let contents = try fileManager.contentsOfDirectory(at: fixtureDir, includingPropertiesForKeys: nil)

        var fixtures: [LyricFixture] = []

        for jsonURL in contents where jsonURL.pathExtension == "json" {
            let id = jsonURL.deletingPathExtension().lastPathComponent
            let wavURL = fixtureDir.appendingPathComponent("\(id).wav")

            guard fileManager.fileExists(atPath: wavURL.path) else {
                continue
            }

            let jsonData = try Data(contentsOf: jsonURL)
            let decoder = JSONDecoder()
            let manifest = try decoder.decode(LyricFixtureManifest.self, from: jsonData)

            // Parse words from manifest
            let words = manifest.words.map { w in
                GroundTruth.WordAnnotation(
                    text: w.text,
                    startTime: w.startTime >= 0 ? w.startTime : -1,
                    endTime: w.endTime >= 0 ? w.endTime : -1,
                    confidence: 1.0
                )
            }

            let category = Category(rawValue: manifest.category) ?? .baseline
            let fixture = LyricFixture(id: id, category: category, audioURL: wavURL, words: words)
            fixtures.append(fixture)
        }

        return fixtures.sorted { $0.id < $1.id }
    }

    /// Get the fixture directory path.
    static func fixtureDirectory() -> URL? {
        let testsPath = ProcessInfo.processInfo.environment["SRCROOT"] ?? Bundle.main.bundlePath

        let testsBundleURL = URL(fileURLWithPath: testsPath)
        let fixtureURL = testsBundleURL
            .appendingPathComponent("Tests")
            .appendingPathComponent("MusicCraftCoreTests")
            .appendingPathComponent("AudioAnalysis")
            .appendingPathComponent("Fixtures")
            .appendingPathComponent("real-audio")
            .appendingPathComponent("lyrics")
            .appendingPathComponent("tts")

        // Fallback: search relative to test bundle
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: fixtureURL.path) {
            return fixtureURL
        }

        // Try relative to current working directory (for CLI test runs)
        let cwd = FileManager.default.currentDirectoryPath
        let cwdURL = URL(fileURLWithPath: cwd)
        let cwdFixtureURL = cwdURL
            .appendingPathComponent("Tests")
            .appendingPathComponent("MusicCraftCoreTests")
            .appendingPathComponent("AudioAnalysis")
            .appendingPathComponent("Fixtures")
            .appendingPathComponent("real-audio")
            .appendingPathComponent("lyrics")
            .appendingPathComponent("tts")

        if fileManager.fileExists(atPath: cwdFixtureURL.path) {
            return cwdFixtureURL
        }

        return nil
    }
}

// MARK: - Fixture Manifest

struct LyricFixtureManifest: Codable {
    let id: String
    let text: String
    let category: String
    let words: [WordEntry]

    struct WordEntry: Codable {
        let text: String
        let startTime: Double
        let endTime: Double
    }
}

/// Static manifest of utterances to generate via TTS.
struct LyricFixtureManifest_Generator {
    struct Entry {
        let id: String
        let text: String
        let category: String
    }

    static let all: [Entry] = [
        Entry(id: "hello-world", text: "hello world", category: "baseline"),
        Entry(id: "quick-brown-fox", text: "the quick brown fox jumps over the lazy dog", category: "pangram"),
        Entry(id: "seashells", text: "she sells seashells by the seashore", category: "phonetic"),
        Entry(id: "coffee-spoons", text: "I have measured out my life with coffee spoons", category: "songlike"),
        Entry(id: "leaves-crispy", text: "the leaves they were crispy and sere", category: "songlike"),
        Entry(id: "homophones", text: "their there they're", category: "homophone"),
        Entry(id: "numbers", text: "one two three four five six seven eight nine ten", category: "numbers"),
        Entry(id: "streetlight", text: "the streetlight hums the porch is warm", category: "songlike"),
        Entry(id: "morning", text: "I will be home before the morning", category: "songlike"),
        Entry(id: "long-passage", text: "the summer air was still and warm the fields were golden in the evening light and somewhere in the distance church bells rang across the quiet valley", category: "longPassage"),
    ]
}
