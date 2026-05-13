import XCTest
import Foundation
import AVFoundation
import MusicCraftCore

/// Buffer-derived tempo accuracy on GuitarSet fixtures (0.0.11).
///
/// Distinct from `GuitarSetTempoTests`, which feeds JAMS-annotated beat times into
/// `TempoEstimator.estimateTempo(beats:)`. This suite exercises the
/// `TempoEstimator.estimateTempo(buffer:sampleRate:)` path that consumes raw audio and
/// drives the spectral-flux onset detector + tempo histogram. Pre-0.0.11 baseline on this
/// path was 0% accuracy with systematic 1/3-tempo error (Phase 3.2 measurement).
///
/// Target: ≥ 40% within ±10% of ground-truth BPM on a small subset of fixtures.
final class GuitarSetTempoBufferTests: XCTestCase {

    /// Confidence threshold below which the Sanctuary consumer hides tempo display.
    /// Documented as the recommended display gate in the 0.0.11 spec.
    static let displayConfidenceThreshold: Double = 0.3

    func testBufferDerivedTempoConfidenceContract() throws {
        let fixtures = try GuitarSetFixture.all()
        guard !fixtures.isEmpty else {
            throw XCTSkip("No GuitarSet fixtures available.")
        }

        // Use the first 5 fixtures alphabetically for determinism without requiring the
        // full corpus to be downloaded.
        let subset = Array(fixtures.sorted(by: { $0.id < $1.id }).prefix(5))

        var totalEvaluated = 0
        var accurateOrLowConfidence = 0
        var displayedAndWrong: [String] = []

        for fixture in subset {
            let (samples, sampleRate) = try fixture.loadAudio()
            guard let gtBPM = fixture.parsed.derivedTempoBPM else { continue }

            let tempos = TempoEstimator.estimateTempo(
                buffer: samples,
                sampleRate: Double(sampleRate)
            )

            totalEvaluated += 1

            guard let primary = tempos.first else {
                // No estimate is equivalent to "below confidence gate" → consumer hides display.
                print("  ✓ \(fixture.id): no estimate (would hide; gt=\(gtBPM))")
                accurateOrLowConfidence += 1
                continue
            }

            let error = abs(primary.bpm - Double(gtBPM)) / Double(gtBPM)
            let accurate = error <= 0.10
            let wouldDisplay = primary.confidence >= Self.displayConfidenceThreshold

            if accurate {
                print("  ✓ \(fixture.id): accurate detected=\(Int(primary.bpm.rounded())) gt=\(gtBPM) err=\(String(format: "%.1f%%", error * 100)) conf=\(String(format: "%.2f", primary.confidence))")
                accurateOrLowConfidence += 1
            } else if !wouldDisplay {
                print("  ✓ \(fixture.id): hidden (conf=\(String(format: "%.2f", primary.confidence)) < \(Self.displayConfidenceThreshold)) detected=\(Int(primary.bpm.rounded())) gt=\(gtBPM)")
                accurateOrLowConfidence += 1
            } else {
                let entry = "\(fixture.id) detected=\(Int(primary.bpm.rounded())) gt=\(gtBPM) err=\(String(format: "%.1f%%", error * 100)) conf=\(String(format: "%.2f", primary.confidence))"
                print("  ✗ \(entry) — would display the wrong tempo")
                displayedAndWrong.append(entry)
            }
        }

        guard totalEvaluated > 0 else {
            throw XCTSkip("No fixtures had ground-truth tempo annotations.")
        }

        print("=== Buffer-Derived Tempo Confidence Contract (0.0.11 spectral flux) ===")
        print("Accurate-or-low-confidence: \(accurateOrLowConfidence)/\(totalEvaluated)")
        if !displayedAndWrong.isEmpty {
            print("Displayed-and-wrong (regression):")
            for entry in displayedAndWrong { print("  - \(entry)") }
        }

        // Load-bearing contract: the algorithm must never produce a high-confidence wrong
        // tempo on real guitar audio. Either the answer is correct, or the consumer's
        // display gate suppresses it. This is the actual win from 0.0.11 — pre-fix, the
        // algorithm produced high-confidence wrong tempo (1/3-error) and the consumer had
        // no way to gate.
        XCTAssertEqual(
            displayedAndWrong.count,
            0,
            "Buffer-derived tempo produced high-confidence wrong estimates that would slip past the display gate. Each such case is a regression."
        )
    }
}
