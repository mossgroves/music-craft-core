import XCTest
import AVFoundation
@testable import MusicCraftCore

/// Tests for the additive `AudioExtractor` note-source switch (`.dsp` default / `.basicPitch`).
/// Assertions are STRUCTURAL — accuracy is the bench's job (`BasicPitchVsCurrentChordBench`); these
/// only guarantee the default is unchanged and the `.basicPitch` path returns a well-formed `Result`.
final class AudioExtractorNoteSourceTests: XCTestCase {

    func testDefaultNoteSourceIsDSP() {
        XCTAssertEqual(AudioExtractor.Configuration().noteSource, .dsp)
        XCTAssertEqual(AudioExtractor.Configuration.default.noteSource, .dsp)
    }

    func testConfigurationIsValueTypeAndHashable() {
        let dsp = AudioExtractor.Configuration(noteSource: .dsp)
        let bp = AudioExtractor.Configuration(noteSource: .basicPitch)
        XCTAssertNotEqual(dsp, bp)
        XCTAssertEqual(Set([dsp, bp]).count, 2)            // distinct & Hashable
        XCTAssertEqual(dsp, AudioExtractor.Configuration()) // default really is .dsp
    }

    func testBasicPitchProducesWellFormedResult() throws {
        guard let gadaDir = fixturesDir(named: "real-audio/gada") else { throw XCTSkip("GADA fixtures not available") }
        // Skip cleanly where Core ML can't load the bundled model (the .basicPitch path degrades to
        // an empty Result there; the device/Xcode run is authoritative).
        do { _ = try BasicPitchTranscriber() }
        catch { throw XCTSkip("Bundled Core ML model could not load under this runner (\(error)).") }

        let fm = FileManager.default
        guard let wav = ((try? fm.contentsOfDirectory(at: gadaDir, includingPropertiesForKeys: nil)) ?? [])
            .filter({ $0.pathExtension == "wav" }).sorted(by: { $0.lastPathComponent < $1.lastPathComponent }).first
        else { throw XCTSkip("no GADA wav files") }

        let label = wav.lastPathComponent.components(separatedBy: "_").dropFirst().first ?? "?"   // GADA: parts[1]
        guard let (samples, sr) = loadMono(wav) else { throw XCTSkip("could not decode \(wav.lastPathComponent)") }

        let result = AudioExtractor.extract(
            buffer: samples, sampleRate: sr,
            configuration: AudioExtractor.Configuration(noteSource: .basicPitch)
        )

        // Structural well-formedness (no accuracy gate).
        XCTAssertFalse(result.chordSegments.isEmpty, "expected at least one chord segment from .basicPitch")
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
        print("\n[.basicPitch] \(wav.lastPathComponent): label \(label) → first chord \(detected); "
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
