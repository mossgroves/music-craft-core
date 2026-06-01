import XCTest
import AVFoundation
@testable import MusicCraftCore

/// Structural tests for `AudioExtractor.extract` — the single Basic Pitch + note-native path (the
/// `.dsp` note-source switch was removed in 0.1.0). Assertions are STRUCTURAL — accuracy is scored in
/// `RealAudioChordTests` and the `BasicPitchChordBench`; these only guarantee the path returns a
/// well-formed `Result` from real audio.
final class AudioExtractorBasicPitchPathTests: XCTestCase {

    func testConfigurationIsValueType() {
        XCTAssertEqual(AudioExtractor.Configuration(), AudioExtractor.Configuration.default)
        XCTAssertEqual(Set([AudioExtractor.Configuration.default]).count, 1)   // Hashable
    }

    func testExtractProducesWellFormedResult() throws {
        guard let gadaDir = fixturesDir(named: "real-audio/gada") else { throw XCTSkip("GADA fixtures not available") }
        // Skip cleanly where Core ML can't load the bundled model (the path degrades to an empty
        // Result there; the device/Xcode run is authoritative).
        do { _ = try BasicPitchTranscriber() }
        catch { throw XCTSkip("Bundled Core ML model could not load under this runner (\(error)).") }

        let fm = FileManager.default
        guard let wav = ((try? fm.contentsOfDirectory(at: gadaDir, includingPropertiesForKeys: nil)) ?? [])
            .filter({ $0.pathExtension == "wav" }).sorted(by: { $0.lastPathComponent < $1.lastPathComponent }).first
        else { throw XCTSkip("no GADA wav files") }

        let label = wav.lastPathComponent.components(separatedBy: "_").dropFirst().first ?? "?"   // GADA: parts[1]
        guard let (samples, sr) = loadMono(wav) else { throw XCTSkip("could not decode \(wav.lastPathComponent)") }

        let result = AudioExtractor.extract(buffer: samples, sampleRate: sr)

        // Structural well-formedness (no accuracy gate).
        XCTAssertFalse(result.chordSegments.isEmpty, "expected at least one chord segment from extract")
        XCTAssertGreaterThan(result.duration, 0)
        for seg in result.chordSegments {
            XCTAssertGreaterThanOrEqual(seg.endTime, seg.startTime, "segment end must be ≥ start")
            XCTAssertEqual(seg.detectionMethod, .classifier)          // reused existing case
            XCTAssertGreaterThanOrEqual(seg.confidence, 0)
            XCTAssertLessThanOrEqual(seg.confidence, 1)
        }

        // Print (not assert) the detected chord vs label and the inferred key.
        let detected = result.chordSegments.first?.chord.displayName ?? "—"
        let keyStr = result.key?.displayName ?? "nil"
        print("\n[extract] \(wav.lastPathComponent): label \(label) → first chord \(detected); "
            + "key \(keyStr); segments \(result.chordSegments.count); notes \(result.detectedNotes.count); contour \(result.contour.count)\n")
    }

    // MARK: - Helpers

    private func loadMono(_ url: URL) -> (samples: [Float], sampleRate: Double)? {
        guard let f = try? AVAudioFile(forReading: url),
              let buf = AVAudioPCMBuffer(pcmFormat: f.processingFormat, frameCapacity: AVAudioFrameCount(f.length)),
              (try? f.read(into: buf)) != nil, let ch0 = buf.floatChannelData?[0] else { return nil }
        return (Array(UnsafeBufferPointer(start: ch0, count: Int(buf.frameLength))), f.processingFormat.sampleRate)
    }

    private func fixturesDir(named: String) -> URL? {
        let bundleURL = Bundle(for: type(of: self)).bundleURL
        let standard = bundleURL.deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("AudioAnalysis").appendingPathComponent("Fixtures").appendingPathComponent(named)
        if FileManager.default.fileExists(atPath: standard.path) { return standard }
        let alt = "/Users/chris/Documents/Code/mossgroves-music-craft-core/.build/arm64-apple-macosx/debug/MusicCraftCore_MusicCraftCoreTests.bundle/Fixtures/\(named)"
        return FileManager.default.fileExists(atPath: alt) ? URL(fileURLWithPath: alt) : nil
    }
}
