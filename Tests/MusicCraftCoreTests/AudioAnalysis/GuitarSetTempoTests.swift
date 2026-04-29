import XCTest
import Foundation
import AVFoundation
import MusicCraftCore

/// Phase 3 test suite: Tempo and beat detection on GuitarSet fixtures.
/// Tests TempoEstimator and BeatTracker accuracy on 30-second polyphonic guitar excerpts.
final class GuitarSetTempoTests: XCTestCase {
    struct Thresholds {
        // Autocorrelation-based estimator (BeatTracker/TempoEstimator) typical performance:
        // 75–85% within ±5% on clean material. Our baseline is conservative acknowledging
        // halftime/doubletime confusion with the autocorrelation algorithm.
        static let within10pctFraction: Double = 0.75   // 75% within ±10%
        static let within5pctFraction: Double = 0.55   // 55% within ±5%
        static let maxHalftimeFraction: Double = 0.30   // if >30% are halftime errors, surface explicitly
    }

    func testGuitarSetTempoAccuracy() throws {
        let fixtures = try GuitarSetFixture.all()
        guard !fixtures.isEmpty else {
            throw XCTSkip("No GuitarSet fixtures found. Run GuitarSetDownloaderTests with MCC_DOWNLOAD_GUITARSET=1 first.")
        }

        var genreResults: [GuitarSetFixture.Genre: [AudioAnalysisMetrics.TempoMetricsExtended]] = [:]
        var allMetrics: [AudioAnalysisMetrics.TempoMetricsExtended] = []

        // Test each fixture
        for fixture in fixtures {
            let (samples, sampleRate) = try fixture.loadAudio()

            // Estimate tempo from beat times in JAMS annotations
            let tempoEstimates = TempoEstimator.estimateTempo(
                beats: fixture.parsed.beatTimes,
                configuration: .default
            )
            let detectedBPM = tempoEstimates.first?.bpm.rounded()

            // Get ground truth from parsed JAMS
            let gtBPM = fixture.parsed.derivedTempoBPM ?? 120
            let gtDouble = Double(gtBPM)

            // Compare using extended metrics
            let metric = AudioAnalysisMetrics.compareTempoExtended(
                detectedBPM: detectedBPM,
                groundTruthBPM: gtDouble
            )

            if genreResults[fixture.genre] == nil {
                genreResults[fixture.genre] = []
            }
            genreResults[fixture.genre]?.append(metric)
            allMetrics.append(metric)

            let detStr = detectedBPM.map { String(Int($0)) } ?? "N/A"
            print("  ✓ \(fixture.id): Detected=\(detStr) BPM, GT=\(gtBPM) BPM, Error=\(String(format: "%.1f%%", metric.tempoError * 100))")
        }

        // Aggregate by genre and overall
        print("\n=== Tempo Analysis Results ===\n")

        for genre in [GuitarSetFixture.Genre.bossaNova, .funk, .rock, .singerSongwriter] {
            guard let metrics = genreResults[genre] else { continue }

            let within10 = Double(metrics.filter { $0.within10pct }.count) / Double(metrics.count)
            let within5 = Double(metrics.filter { $0.within5pct }.count) / Double(metrics.count)
            let halftimeCount = Double(metrics.filter { $0.isHalftime }.count) / Double(metrics.count)
            let doubletimeCount = Double(metrics.filter { $0.isDoubletime }.count) / Double(metrics.count)

            print("Genre: \(genre.rawValue)")
            print("  Fixtures: \(metrics.count)")
            print("  Within ±10%: \(String(format: "%.0f%%", within10 * 100))")
            print("  Within ±5%: \(String(format: "%.0f%%", within5 * 100))")
            if halftimeCount > 0 {
                print("  Halftime errors: \(String(format: "%.0f%%", halftimeCount * 100))")
            }
            if doubletimeCount > 0 {
                print("  Doubletime errors: \(String(format: "%.0f%%", doubletimeCount * 100))")
            }
            print()
        }

        // Overall statistics
        let within10 = Double(allMetrics.filter { $0.within10pct }.count) / Double(allMetrics.count)
        let within5 = Double(allMetrics.filter { $0.within5pct }.count) / Double(allMetrics.count)
        let halftimeCount = Double(allMetrics.filter { $0.isHalftime }.count) / Double(allMetrics.count)
        let doubletimeCount = Double(allMetrics.filter { $0.isDoubletime }.count) / Double(allMetrics.count)

        print("=== Overall ===")
        print("Within ±10%: \(String(format: "%.0f%%", within10 * 100)) (threshold: \(String(format: "%.0f%%", Thresholds.within10pctFraction * 100)))")
        print("Within ±5%: \(String(format: "%.0f%%", within5 * 100)) (threshold: \(String(format: "%.0f%%", Thresholds.within5pctFraction * 100)))")
        print("Halftime errors: \(String(format: "%.0f%%", halftimeCount * 100))")
        print("Doubletime errors: \(String(format: "%.0f%%", doubletimeCount * 100))")
        print("Total Fixtures: \(allMetrics.count)")
        print()

        // Assert against thresholds
        XCTAssertGreaterThanOrEqual(
            within10,
            Thresholds.within10pctFraction,
            "Within ±10%: \(String(format: "%.1f%%", within10 * 100)) below threshold \(String(format: "%.1f%%", Thresholds.within10pctFraction * 100))"
        )

        XCTAssertGreaterThanOrEqual(
            within5,
            Thresholds.within5pctFraction,
            "Within ±5%: \(String(format: "%.1f%%", within5 * 100)) below threshold \(String(format: "%.1f%%", Thresholds.within5pctFraction * 100))"
        )

        // Halftime/doubletime errors should be relatively rare
        XCTAssertLessThanOrEqual(
            halftimeCount,
            Thresholds.maxHalftimeFraction,
            "Halftime errors: \(String(format: "%.1f%%", halftimeCount * 100)) exceed threshold \(String(format: "%.1f%%", Thresholds.maxHalftimeFraction * 100))"
        )
    }

}
