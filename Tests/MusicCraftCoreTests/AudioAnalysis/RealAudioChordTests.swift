import XCTest
import AVFoundation
@testable import MusicCraftCore

/// Real-audio chord detection tests using GADA and TaylorNylon fixtures.
/// Scores `AudioExtractor.extract` (the Basic Pitch + note-native chord path — the only path as of 0.1.0)
/// against the Stage 2 baseline accuracy thresholds derived from legacy Cantus AudioExtractor.
final class RealAudioChordTests: XCTestCase {

    // MARK: - Baseline Thresholds

    struct Thresholds {
        // As of 0.1.0 these score the Basic Pitch + note-native chord path. That path replaced the
        // chroma+template `ChordDetector` that produced the Phase 2.6/2.7 product gap (40.6% GADA root /
        // 31.2% TaylorNylon root, which these thresholds were set high to surface). The note-native namer
        // measures ≈99–100% root/exact on these single-chord fixtures (see BasicPitchChordBench), so these
        // thresholds now validate the consolidation rather than demand a fix. Stage 2 legacy baseline
        // (99.7% GADA root, 88.1% TaylorNylon root) remains the long-term target.
        static let gadaRootAccuracy: Double = 0.95
        static let gadaExactAccuracy: Double = 0.90
        static let taylorNylonRootAccuracy: Double = 0.80
        static let taylorNylonExactAccuracy: Double = 0.65
    }

    /// The chord path runs the bundled Basic Pitch Core ML model; skip cleanly where it can't load
    /// under this runner (the device/Xcode run is authoritative — same posture as the transcriber tests).
    private func skipUnlessBasicPitchModelLoads() throws {
        do { _ = try BasicPitchTranscriber() }
        catch { throw XCTSkip("Bundled Core ML model could not load under this runner (\(error)).") }
    }

    // MARK: - GADA Tests

    func testGADAChordAccuracy() throws {
        try skipUnlessBasicPitchModelLoads()
        guard let gadaDir = getFixturesDirectory(named: "real-audio/gada") else {
            throw XCTSkip("GADA fixtures not available")
        }

        let (rootCorrect, exactCorrect, total, confusions) = try testChordFiles(in: gadaDir)

        let rootAccuracy = Double(rootCorrect) / Double(total)
        let exactAccuracy = Double(exactCorrect) / Double(total)

        print("""
            GADA subset (\(total) files): root \(rootCorrect)/\(total) = \(String(format: "%.1f%%", rootAccuracy * 100)), \
            exact \(exactCorrect)/\(total) = \(String(format: "%.1f%%", exactAccuracy * 100))
            """)

        if !confusions.isEmpty {
            print("  Confusions: \(confusions.sorted().joined(separator: ", "))")
        }

        XCTAssertGreaterThanOrEqual(rootAccuracy, Thresholds.gadaRootAccuracy,
            "GADA root accuracy \(String(format: "%.1f%%", rootAccuracy * 100)) should be ≥\(String(format: "%.0f%%", Thresholds.gadaRootAccuracy * 100))")

        XCTAssertGreaterThanOrEqual(exactAccuracy, Thresholds.gadaExactAccuracy,
            "GADA exact accuracy \(String(format: "%.1f%%", exactAccuracy * 100)) should be ≥\(String(format: "%.0f%%", Thresholds.gadaExactAccuracy * 100))")
    }

    // MARK: - TaylorNylon Tests

    func testTaylorNylonChordAccuracy() throws {
        try skipUnlessBasicPitchModelLoads()
        guard let taylorDir = getFixturesDirectory(named: "real-audio/taylor-nylon") else {
            throw XCTSkip("TaylorNylon fixtures not available")
        }

        let (rootCorrect, exactCorrect, total, confusions) = try testChordDirs(in: taylorDir)

        let rootAccuracy = Double(rootCorrect) / Double(total)
        let exactAccuracy = Double(exactCorrect) / Double(total)

        print("""
            TaylorNylon subset (\(total) files): root \(rootCorrect)/\(total) = \(String(format: "%.1f%%", rootAccuracy * 100)), \
            exact \(exactCorrect)/\(total) = \(String(format: "%.1f%%", exactAccuracy * 100))
            """)

        if !confusions.isEmpty {
            print("  Confusions: \(confusions.sorted().joined(separator: ", "))")
        }

        XCTAssertGreaterThanOrEqual(rootAccuracy, Thresholds.taylorNylonRootAccuracy,
            "TaylorNylon root accuracy \(String(format: "%.1f%%", rootAccuracy * 100)) should be ≥\(String(format: "%.0f%%", Thresholds.taylorNylonRootAccuracy * 100))")

        XCTAssertGreaterThanOrEqual(exactAccuracy, Thresholds.taylorNylonExactAccuracy,
            "TaylorNylon exact accuracy \(String(format: "%.1f%%", exactAccuracy * 100)) should be ≥\(String(format: "%.0f%%", Thresholds.taylorNylonExactAccuracy * 100))")
    }

    // MARK: - Test Helpers

    private func getFixturesDirectory(named: String) -> URL? {
        let testBundleURL = Bundle(for: type(of: self)).bundleURL

        // Try the standard path first (relative to test bundle)
        let standardPath = testBundleURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("AudioAnalysis")
            .appendingPathComponent("Fixtures")
            .appendingPathComponent(named)

        if FileManager.default.fileExists(atPath: standardPath.path) {
            return standardPath
        }

        // Try alternate bundle locations (for CLI test runner compatibility)
        let searchPaths = [
            "/Users/chris/Documents/Code/mossgroves-music-craft-core/.build/arm64-apple-macosx/debug/MusicCraftCore_MusicCraftCoreTests.bundle/Fixtures/\(named)",
        ]

        for path in searchPaths {
            let url = URL(fileURLWithPath: path)
            if FileManager.default.fileExists(atPath: url.path) {
                return url
            }
        }

        return nil
    }

    private func testChordFiles(in directory: URL) throws -> (rootCorrect: Int, exactCorrect: Int, total: Int, confusions: [String]) {
        let fileManager = FileManager.default
        guard let contents = try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else {
            return (0, 0, 0, [])
        }

        let wavFiles = contents.filter { $0.pathExtension == "wav" }
        var rootCorrect = 0
        var exactCorrect = 0
        var confusionCounts: [String: Int] = [:]

        for wavFile in wavFiles {
            let chordLabel = parseGADAFilename(wavFile.lastPathComponent)
            // Parse the label through Chord(parsing:) so the comparison is canonical (pitch-class root +
            // quality enum). Comparing a root-only displayName ("A") to a quality-bearing label ("Am")
            // would falsely miss every non-major chord.
            guard let groundTruthChord = chordLabel, let truthChord = Chord(parsing: groundTruthChord) else { continue }

            // Load audio
            guard let audioFile = try? AVAudioFile(forReading: wavFile),
                  let buffer = AVAudioPCMBuffer(pcmFormat: audioFile.processingFormat,
                                               frameCapacity: AVAudioFrameCount(audioFile.length)) else {
                continue
            }

            try audioFile.read(into: buffer)
            guard let floatData = buffer.floatChannelData else { continue }

            let frameLength = Int(buffer.frameLength)
            let samples = Array<Float>(UnsafeBufferPointer(start: floatData[0], count: frameLength))

            // Extract and evaluate
            let result = AudioExtractor.extract(buffer: samples, sampleRate: audioFile.processingFormat.sampleRate)

            if let segment = result.chordSegments.first {
                let detected = segment.chord
                if detected.root == truthChord.root { rootCorrect += 1 }
                if detected.root == truthChord.root && detected.quality == truthChord.quality {
                    exactCorrect += 1
                } else {
                    let confusion = "\(groundTruthChord)→\(detected.displayName)"
                    confusionCounts[confusion, default: 0] += 1
                }
            }
            // If no segments detected, count as wrong (implicitly)
        }

        // Convert confusion counts to summary strings
        let confusions = confusionCounts.map { "\($0.key)×\($0.value)" }

        return (rootCorrect, exactCorrect, wavFiles.count, confusions)
    }

    private func testChordDirs(in directory: URL) throws -> (rootCorrect: Int, exactCorrect: Int, total: Int, confusions: [String]) {
        let fileManager = FileManager.default
        guard let contents = try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else {
            return (0, 0, 0, [])
        }

        let chordFolders = contents.filter { url in
            var isDir: ObjCBool = false
            fileManager.fileExists(atPath: url.path, isDirectory: &isDir)
            return isDir.boolValue
        }

        var totalRootCorrect = 0
        var totalExactCorrect = 0
        var totalCount = 0
        var allConfusions: [String: Int] = [:]

        for folder in chordFolders {
            let groundTruthChord = folder.lastPathComponent
            // Canonical comparison (see testChordFiles): root-only displayName vs quality-bearing label
            // would falsely miss every non-major chord.
            guard let truthChord = Chord(parsing: groundTruthChord) else { continue }
            guard let wavFiles = try? fileManager.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) else {
                continue
            }

            for wavFile in wavFiles where wavFile.pathExtension == "wav" {
                // Load audio
                guard let audioFile = try? AVAudioFile(forReading: wavFile),
                      let buffer = AVAudioPCMBuffer(pcmFormat: audioFile.processingFormat,
                                                   frameCapacity: AVAudioFrameCount(audioFile.length)) else {
                    continue
                }

                try audioFile.read(into: buffer)
                guard let floatData = buffer.floatChannelData else { continue }

                let frameLength = Int(buffer.frameLength)
                let samples = Array<Float>(UnsafeBufferPointer(start: floatData[0], count: frameLength))

                // Extract and evaluate
                let result = AudioExtractor.extract(buffer: samples, sampleRate: audioFile.processingFormat.sampleRate)

                if let segment = result.chordSegments.first {
                    let detected = segment.chord
                    if detected.root == truthChord.root { totalRootCorrect += 1 }
                    if detected.root == truthChord.root && detected.quality == truthChord.quality {
                        totalExactCorrect += 1
                    } else {
                        let confusion = "\(groundTruthChord)→\(detected.displayName)"
                        allConfusions[confusion, default: 0] += 1
                    }
                }
                // If no segments detected, count as wrong (implicitly)

                totalCount += 1
            }
        }

        // Convert confusion counts to summary strings
        let confusions = allConfusions.map { "\($0.key)×\($0.value)" }

        return (totalRootCorrect, totalExactCorrect, totalCount, confusions)
    }

    private func parseGADAFilename(_ filename: String) -> String? {
        // Format: ArgSG_Am_open_022_ID4_1.wav
        // parts[0]=ArgSG, parts[1]=Am, parts[2]=open, ...
        let baseName = (filename as NSString).deletingPathExtension
        let parts = baseName.components(separatedBy: "_")
        guard parts.count >= 2 else { return nil }
        return parts[1]  // Chord label is second component
    }
}
