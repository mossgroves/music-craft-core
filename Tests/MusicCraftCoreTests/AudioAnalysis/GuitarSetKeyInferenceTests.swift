import XCTest
import Foundation
import AVFoundation
import MusicCraftCore

/// Phase 3 test suite: Key inference on GuitarSet chord-rich fixtures.
/// Tests MelodyKeyInference (via AudioExtractor.extract) on multi-chord comping material.
///
/// SCOPE LIMITATION: Phase 3 measures key inference on chord-rich comping material only.
/// AudioExtractor uses chord-based key inference as the primary path when ≥2 distinct
/// chords are detected. MelodyKeyInference's pitch-class fallback path is NOT exercised.
/// Do not claim general key-inference accuracy from Phase 3 data.
final class GuitarSetKeyInferenceTests: XCTestCase {
    struct Thresholds {
        // State-of-the-art key detection (Krumhansl-Schmuckler, chord-based): 70–75% exact.
        // AudioExtractor uses chord-based inference as primary path for multi-chord clips.
        // Initial thresholds conservative; will adjust after first-run measurement.
        // Calibration-down rule: acceptable only if first-run is within ~15pp of literature
        // baseline (70–75% exact). If gap is >15pp, surface as a finding — do not lower.
        static let exactMatchFraction: Double = 0.60    // 60% exact (root + mode)
        static let relativeKeyFraction: Double = 0.75   // 75% counting relative keys as correct
    }

    func testGuitarSetKeyInferenceAccuracy() throws {
        let fixtures = try GuitarSetFixture.all()
        guard !fixtures.isEmpty else {
            throw XCTSkip("No GuitarSet fixtures found. Run GuitarSetDownloaderTests with MCC_DOWNLOAD_GUITARSET=1 first.")
        }

        var genreResults: [GuitarSetFixture.Genre: [AudioAnalysisMetrics.KeyMetrics]] = [:]
        var allMetrics: [AudioAnalysisMetrics.KeyMetrics] = []

        // Test each fixture
        for fixture in fixtures {
            guard let gtKey = fixture.parsed.key else {
                // Skip fixtures without key annotation
                continue
            }

            let (samples, sampleRate) = try fixture.loadAudio()

            // Run AudioExtractor
            let result = try AudioExtractor.extract(buffer: samples, sampleRate: Double(sampleRate))

            // Compare against ground truth
            let metric = AudioAnalysisMetrics.compareKey(
                detected: result.key,
                groundTruthJAMS: gtKey
            )

            if genreResults[fixture.genre] == nil {
                genreResults[fixture.genre] = []
            }
            genreResults[fixture.genre]?.append(metric)
            allMetrics.append(metric)

            let detStr = metric.detectedKey ?? "N/A"
            let exactStr = metric.exactMatch ? "✓" : "✗"
            print("  \(exactStr) \(fixture.id): Detected=\(detStr), GT=\(gtKey)")
        }

        guard !allMetrics.isEmpty else {
            throw XCTSkip("No fixtures with key annotations found.")
        }

        // Aggregate by genre
        print("\n=== Key Inference Results ===\n")

        for genre in [GuitarSetFixture.Genre.bossaNova, .funk, .rock, .singerSongwriter] {
            guard let metrics = genreResults[genre], !metrics.isEmpty else { continue }

            let exact = Double(metrics.filter { $0.exactMatch }.count) / Double(metrics.count)
            let relative = Double(metrics.filter { $0.relativeKeyMatch }.count) / Double(metrics.count)
            let rootOnly = Double(metrics.filter { $0.rootMatch && !$0.exactMatch }.count) / Double(metrics.count)
            let miss = Double(metrics.filter { !$0.rootMatch }.count) / Double(metrics.count)

            print("Genre: \(genre.rawValue)")
            print("  Fixtures: \(metrics.count)")
            print("  Exact Match (root+mode): \(String(format: "%.0f%%", exact * 100))")
            print("  Relative Key Match: \(String(format: "%.0f%%", relative * 100))")
            print("  Root Match (mode diff): \(String(format: "%.0f%%", rootOnly * 100))")
            print("  Miss (wrong root): \(String(format: "%.0f%%", miss * 100))")
            print()
        }

        // Overall statistics
        let exact = Double(allMetrics.filter { $0.exactMatch }.count) / Double(allMetrics.count)
        let relative = Double(allMetrics.filter { $0.relativeKeyMatch }.count) / Double(allMetrics.count)
        let rootOnly = Double(allMetrics.filter { $0.rootMatch && !$0.exactMatch }.count) / Double(allMetrics.count)
        let miss = Double(allMetrics.filter { !$0.rootMatch }.count) / Double(allMetrics.count)

        print("=== Overall ===")
        print("Exact Match (root+mode): \(String(format: "%.0f%%", exact * 100)) (threshold: \(String(format: "%.0f%%", Thresholds.exactMatchFraction * 100)))")
        print("Relative Key Match: \(String(format: "%.0f%%", relative * 100)) (threshold: \(String(format: "%.0f%%", Thresholds.relativeKeyFraction * 100)))")
        print("Root Match (mode diff): \(String(format: "%.0f%%", rootOnly * 100))")
        print("Miss (wrong root): \(String(format: "%.0f%%", miss * 100))")
        print("Total Fixtures: \(allMetrics.count)")
        print()

        print("NOTE: Phase 3 measures key inference on chord-rich comping material only.")
        print("AudioExtractor uses chord-based inference when ≥2 distinct chords detected.")
        print("MelodyKeyInference pitch-class fallback path is NOT exercised by these clips.")
        print()

        // Assert against thresholds
        XCTAssertGreaterThanOrEqual(
            exact,
            Thresholds.exactMatchFraction,
            "Exact match \(String(format: "%.1f%%", exact * 100)) below threshold \(String(format: "%.1f%%", Thresholds.exactMatchFraction * 100))"
        )

        XCTAssertGreaterThanOrEqual(
            relative,
            Thresholds.relativeKeyFraction,
            "Relative key match \(String(format: "%.1f%%", relative * 100)) below threshold \(String(format: "%.1f%%", Thresholds.relativeKeyFraction * 100))"
        )
    }

}
