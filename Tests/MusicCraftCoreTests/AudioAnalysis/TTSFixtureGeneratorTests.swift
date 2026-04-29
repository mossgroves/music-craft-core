import XCTest
import AVFoundation
import Speech

/// Phase 5 TTS fixture generator — gated by MCC_GENERATE_LYRIC_FIXTURES=1.
/// Generates ~10 utterances via AVSpeechSynthesizer and saves as WAV + JSON sidecar.
/// Run: MCC_GENERATE_LYRIC_FIXTURES=1 swift test --filter TTSFixtureGeneratorTests
final class TTSFixtureGeneratorTests: XCTestCase {

    let isGenerationEnabled = ProcessInfo.processInfo.environment["MCC_GENERATE_LYRIC_FIXTURES"] == "1"

    func testGenerateTTSFixtures() async throws {
        guard isGenerationEnabled else {
            throw XCTSkip("TTS generation disabled. Run with MCC_GENERATE_LYRIC_FIXTURES=1 to enable.")
        }

        // Create fixture directory
        guard let fixtureDir = getOrCreateFixtureDirectory() else {
            XCTFail("Failed to create fixture directory")
            return
        }

        print("\n=== GENERATING TTS FIXTURES ===")
        print("Target directory: \(fixtureDir.path)")

        var generatedCount = 0
        var skippedCount = 0

        // Generate each utterance
        for entry in LyricFixtureManifest_Generator.all {
            let wavURL = fixtureDir.appendingPathComponent("\(entry.id).wav")
            let jsonURL = fixtureDir.appendingPathComponent("\(entry.id).json")

            // Skip if both files exist
            if FileManager.default.fileExists(atPath: wavURL.path),
               FileManager.default.fileExists(atPath: jsonURL.path) {
                print("  ⊘ \(entry.id) — already exists, skipping")
                skippedCount += 1
                continue
            }

            do {
                try generateTTSFixture(
                    id: entry.id,
                    text: entry.text,
                    category: entry.category,
                    outputWAV: wavURL,
                    outputJSON: jsonURL
                )
                print("  ✓ \(entry.id) — generated")
                generatedCount += 1
            } catch {
                print("  ✗ \(entry.id) — FAILED: \(error.localizedDescription)")
                throw error
            }
        }

        print("\n=== GENERATION COMPLETE ===")
        print("Generated: \(generatedCount), Skipped: \(skippedCount)")
    }

    // MARK: - Helper: TTS Generation

    private func generateTTSFixture(
        id: String,
        text: String,
        category: String,
        outputWAV: URL,
        outputJSON: URL
    ) throws {
        // Create utterance and synthesizer
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: "en-US")
        utterance.rate = 0.5  // Slower speech for clarity
        utterance.pitchMultiplier = 1.0
        utterance.volume = 1.0

        // Create audio engine for offline rendering
        let audioEngine = AVAudioEngine()
        let synthesizer = AVSpeechSynthesizer()

        // Configure audio format
        let audioFormat = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 1)!

        // mainMixerNode is already attached by default
        let mixer = audioEngine.mainMixerNode
        try audioEngine.connect(mixer, to: audioEngine.outputNode, format: audioFormat)

        // Create output file
        try audioEngine.start()

        // Buffer to accumulate audio
        var audioBuffers: [AVAudioPCMBuffer] = []
        let bufferLock = NSLock()

        // Install tap on mixer to capture audio
        mixer.installTap(onBus: 0, bufferSize: 4096, format: audioFormat) { buffer, _ in
            bufferLock.lock()
            if let copy = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: buffer.frameLength) {
                copy.frameLength = buffer.frameLength
                memcpy(copy.mutableAudioBufferList.pointee.mBuffers.mData,
                       buffer.audioBufferList.pointee.mBuffers.mData,
                       Int(buffer.frameLength) * MemoryLayout<Float>.stride)
                audioBuffers.append(copy)
            }
            bufferLock.unlock()
        }

        // Speak synchronously
        synthesizer.speak(utterance)

        // Wait for synthesis to complete
        let startTime = Date()
        let maxWait = 60.0  // seconds
        while synthesizer.isSpeaking && Date().timeIntervalSince(startTime) < maxWait {
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.1))
        }

        // Remove tap
        mixer.removeTap(onBus: 0)

        // Concatenate buffers
        let totalFrames = audioBuffers.reduce(0) { $0 + Int($1.frameLength) }

        guard let combinedBuffer = AVAudioPCMBuffer(pcmFormat: audioFormat, frameCapacity: AVAudioFrameCount(totalFrames)) else {
            throw NSError(domain: "Audio", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to create combined buffer"])
        }

        var frameOffset: AVAudioFrameCount = 0
        for buffer in audioBuffers {
            if let destData = combinedBuffer.mutableAudioBufferList.pointee.mBuffers.mData,
               let srcData = buffer.audioBufferList.pointee.mBuffers.mData {
                memcpy(
                    destData + Int(frameOffset) * MemoryLayout<Float>.stride,
                    srcData,
                    Int(buffer.frameLength) * MemoryLayout<Float>.stride
                )
            }
            frameOffset += buffer.frameLength
        }
        combinedBuffer.frameLength = frameOffset

        // Write WAV file
        try audioEngine.stop()
        audioEngine.reset()

        let audioFile = try AVAudioFile(forWriting: outputWAV, settings: audioFormat.settings)
        try audioFile.write(from: combinedBuffer)

        // Generate ground truth JSON (words without timing — offline rendering doesn't provide reliable timing)
        let words = text.split(separator: " ").map { String($0) }
        let wordEntries = words.map { word in
            LyricFixtureManifest.WordEntry(text: word, startTime: -1, endTime: -1)
        }

        let manifest = LyricFixtureManifest(
            id: id,
            text: text,
            category: category,
            words: wordEntries
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let jsonData = try encoder.encode(manifest)
        try jsonData.write(to: outputJSON)
    }

    // MARK: - Helper: Directory Management

    private func getOrCreateFixtureDirectory() -> URL? {
        let fileManager = FileManager.default

        // Compute path relative to test source
        var pathComponents: [String] = []

        // Try from SRCROOT
        if let srcRoot = ProcessInfo.processInfo.environment["SRCROOT"] {
            let srcURL = URL(fileURLWithPath: srcRoot)
            let fixtureURL = srcURL
                .appendingPathComponent("Tests")
                .appendingPathComponent("MusicCraftCoreTests")
                .appendingPathComponent("AudioAnalysis")
                .appendingPathComponent("Fixtures")
                .appendingPathComponent("real-audio")
                .appendingPathComponent("lyrics")
                .appendingPathComponent("tts")

            pathComponents = fixtureURL.pathComponents
        } else {
            // Fallback: current working directory
            let cwd = fileManager.currentDirectoryPath
            let cwdURL = URL(fileURLWithPath: cwd)
            let fixtureURL = cwdURL
                .appendingPathComponent("Tests")
                .appendingPathComponent("MusicCraftCoreTests")
                .appendingPathComponent("AudioAnalysis")
                .appendingPathComponent("Fixtures")
                .appendingPathComponent("real-audio")
                .appendingPathComponent("lyrics")
                .appendingPathComponent("tts")

            pathComponents = fixtureURL.pathComponents
        }

        // Build path and create directories
        var currentPath = ""
        for component in pathComponents {
            if component != "/" {
                currentPath = (currentPath as NSString).appendingPathComponent(component)
            } else {
                currentPath = "/"
            }

            var isDir: ObjCBool = false
            if !fileManager.fileExists(atPath: currentPath, isDirectory: &isDir) || !isDir.boolValue {
                do {
                    try fileManager.createDirectory(atPath: currentPath, withIntermediateDirectories: true, attributes: nil)
                } catch {
                    print("Failed to create directory \(currentPath): \(error)")
                    return nil
                }
            }
        }

        return URL(fileURLWithPath: currentPath)
    }
}
