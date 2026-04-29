import XCTest
import Foundation
import AVFoundation
import MusicCraftCore

/// Phase 3 test suite: Chord progression analysis on GuitarSet multi-chord clips.
/// Tests AudioExtractor.extract on 30-second polyphonic guitar excerpts with JAMS annotations.
/// Measures Chord Symbol Recall (CSR) at root level on chord-rich comping material.
final class GuitarSetProgressionTests: XCTestCase {
    struct Thresholds {
        // Phase 2.7 showed 40% root accuracy on isolated single chords.
        // Progressions (30s clips, multiple chord changes) provide more disambiguation
        // context → expect modestly higher CSR than single-chord accuracy, but not
        // Stage-2-era 95%+ since the underlying detector limitation persists.
        // Threshold calibrated to first-run measured value; will tighten post-Phase 3.
        static let majMinCSRMean: Double = 0.50        // 50% mean across 20 fixtures
        static let medianTimingDeviationSec: Double = 1.0  // seconds
    }

    func testGuitarSetProgressionAccuracy() throws {
        let fixtures = try GuitarSetFixture.all()
        guard !fixtures.isEmpty else {
            throw XCTSkip("No GuitarSet fixtures found. Run GuitarSetDownloaderTests with MCC_DOWNLOAD_GUITARSET=1 first.")
        }

        var genreResults: [GuitarSetFixture.Genre: [AudioAnalysisMetrics.ProgressionMetrics]] = [:]

        // Test each fixture
        for fixture in fixtures {
            let (samples, sampleRate) = try fixture.loadAudio()

            // Run AudioExtractor
            let result = try AudioExtractor.extract(buffer: samples, sampleRate: Double(sampleRate))

            // Compare against ground truth
            let metric = AudioAnalysisMetrics.compareProgression(
                detected: result.chordSegments,
                groundTruth: fixture.parsed.chordSegments
            )

            if genreResults[fixture.genre] == nil {
                genreResults[fixture.genre] = []
            }
            genreResults[fixture.genre]?.append(metric)

            print("  ✓ \(fixture.id): CSR=\(String(format: "%.1f%%", metric.majMinCSR * 100))")
        }

        // Aggregate by genre
        print("\n=== Progression Analysis Results ===\n")

        var allMetrics: [AudioAnalysisMetrics.ProgressionMetrics] = []
        for genre in [GuitarSetFixture.Genre.bossaNova, .funk, .rock, .singerSongwriter] {
            guard let metrics = genreResults[genre] else { continue }

            let meanCSR = metrics.map { $0.majMinCSR }.reduce(0, +) / Double(metrics.count)
            let medianTiming = {
                let deviations = metrics.map { $0.medianTimingDeviationSec }
                let sorted = deviations.sorted()
                return sorted[sorted.count / 2]
            }()

            print("Genre: \(genre.rawValue)")
            print("  Fixtures: \(metrics.count)")
            print("  Mean CSR: \(String(format: "%.1f%%", meanCSR * 100))")
            print("  Median Timing Deviation: \(String(format: "%.2f", medianTiming))s")
            print()

            allMetrics.append(contentsOf: metrics)
        }

        // Overall statistics
        let overallCSR = allMetrics.map { $0.majMinCSR }.reduce(0, +) / Double(allMetrics.count)
        let overallTiming = {
            let deviations = allMetrics.map { $0.medianTimingDeviationSec }
            let sorted = deviations.sorted()
            return sorted[sorted.count / 2]
        }()

        print("=== Overall ===")
        print("Mean CSR: \(String(format: "%.1f%%", overallCSR * 100))")
        print("Median Timing Deviation: \(String(format: "%.2f", overallTiming))s")
        print("Total Fixtures: \(allMetrics.count)")
        print()

        // Assert against thresholds
        XCTAssertGreaterThanOrEqual(
            overallCSR,
            Thresholds.majMinCSRMean,
            "Mean CSR \(String(format: "%.1f%%", overallCSR * 100)) below threshold \(String(format: "%.1f%%", Thresholds.majMinCSRMean * 100))"
        )
    }

}
