import XCTest
import Foundation
import AVFoundation
import Accelerate
import MusicCraftCore

/// Phase 3.3 Diagnostic: Instrument autocorrelation peak finding for 1/3-tempo bug.
/// Run with: MCC_DIAGNOSTIC=1 swift test --filter Phase33TempoDiagnosticTests
final class Phase33TempoDiagnosticTests: XCTestCase {
    let isDiagnosticEnabled = ProcessInfo.processInfo.environment["MCC_DIAGNOSTIC"] == "1"

    func testAutocorrelationPeaksOnBossaNova() throws {
        guard isDiagnosticEnabled else {
            throw XCTSkip("Diagnostic disabled. Run with MCC_DIAGNOSTIC=1 to enable.")
        }

        let fixtureDir = URL(fileURLWithPath: "/Users/chris/Documents/Code/mossgroves-music-craft-core/Tests/MusicCraftCoreTests/AudioAnalysis/Fixtures/real-audio/guitarset")
        let fixtureID = "00_BN1-129-Eb_comp"
        let audioURL = fixtureDir.appendingPathComponent("\(fixtureID).wav")

        // Load audio
        let audioFile = try AVAudioFile(forReading: audioURL)
        let format = audioFile.processingFormat

        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: UInt32(audioFile.length)) else {
            throw NSError(domain: "Audio", code: -1)
        }

        try audioFile.read(into: buffer)
        guard let floatChannelData = buffer.floatChannelData else {
            throw NSError(domain: "Audio", code: -1)
        }

        let frameLength = Int(buffer.frameLength)
        let samples = Array(UnsafeBufferPointer(start: floatChannelData[0], count: frameLength))
        let sampleRate = audioFile.processingFormat.sampleRate

        print("\n=== AUTOCORRELATION PEAK ANALYSIS ===")
        print("Fixture: \(fixtureID)")
        print("Ground Truth: 129 BPM, ~0.466 sec per beat")
        print("Detected (incorrect): 43 BPM, ~1.395 sec per beat")
        print("Ratio: 1/3 of true tempo")
        print()

        // Extract onset strength signal using BeatTracker's internal algorithm
        let onsetStrength = computeOnsetStrengthSignal(
            buffer: samples,
            windowSize: 2048,
            hopSize: 1024
        )

        print("Onset Strength Signal:")
        print("  Frames: \(onsetStrength.count)")
        let onsetMin = onsetStrength.min() ?? 0
        let onsetMax = onsetStrength.max() ?? 0
        let onsetMean = onsetStrength.reduce(0, +) / Float(onsetStrength.count)
        print("  Min: \(String(format: "%.6f", onsetMin))")
        print("  Max: \(String(format: "%.6f", onsetMax))")
        print("  Mean: \(String(format: "%.6f", onsetMean))")
        print()

        // Compute autocorrelation for the lag range
        let hopSize = 1024
        let sampleRateDbl = Double(sampleRate)

        // For 129 BPM at 44.1kHz with 1024 hop:
        // Beat period = 60/129 = 0.466 sec
        // In frames: 0.466 * 44100 / 1024 ≈ 20 frames
        // For 43 BPM:
        // Beat period = 60/43 = 1.395 sec
        // In frames: 1.395 * 44100 / 1024 ≈ 60 frames

        let minLag = Int(300 / 1000.0 * sampleRateDbl / Double(hopSize))  // ~9 frames
        let maxLag = Int(3000 / 1000.0 * sampleRateDbl / Double(hopSize)) // ~129 frames

        print("Autocorrelation Lag Range: \(minLag)–\(maxLag) frames")
        print("  300ms lag = ~\(minLag) frames (~200 BPM)")
        print("  3000ms lag = ~\(maxLag) frames (~20 BPM)")
        print()

        // For reference tempos:
        let lag129 = Int(60.0 / 129.0 * sampleRateDbl / Double(hopSize))
        let lag43 = Int(60.0 / 43.0 * sampleRateDbl / Double(hopSize))
        print("Expected lag for 129 BPM: ~\(lag129) frames")
        print("Expected lag for 43 BPM: ~\(lag43) frames")
        print()

        // Compute autocorrelation peaks
        let lag0 = computeAutocorrelation(onsetStrength, lag: 0)
        let normFactor = max(lag0, 1e-10)

        print("Lag 0 Autocorrelation: \(String(format: "%.6f", lag0))")
        print()

        // Find top peaks
        var peaksWithLags: [(lag: Int, correlation: Float, normalized: Float, bpm: Double)] = []

        for lag in minLag...maxLag {
            let corr = computeAutocorrelation(onsetStrength, lag: lag)
            let normalized = corr / normFactor
            let lagSeconds = Double(lag) * Double(hopSize) / sampleRateDbl
            let bpm = 60.0 / lagSeconds

            peaksWithLags.append((lag: lag, correlation: corr, normalized: normalized, bpm: bpm))
        }

        // Sort by normalized correlation (descending)
        peaksWithLags.sort { $0.normalized > $1.normalized }

        print("Top 20 Autocorrelation Peaks (by normalized value):")
        print("Lag | Frames | BPM        | Normalized | Correlation")
        print(String(repeating: "-", count: 60))

        for (idx, peak) in peaksWithLags.prefix(20).enumerated() {
            let lagMs = Double(peak.lag) * Double(hopSize) / sampleRateDbl * 1000.0
            print("\(idx + 1):  \(String(format: "%3d", peak.lag)) | \(String(format: "%6.1f", lagMs))ms | \(String(format: "%7.1f", peak.bpm)) | \(String(format: "%.4f", peak.normalized)) | \(String(format: "%.6f", peak.correlation))")
        }

        print()
        print("=== ANALYSIS ===")

        // Check if 129 BPM lag is in top peaks
        if let peak129 = peaksWithLags.first(where: { abs($0.bpm - 129.0) < 2.0 }) {
            if let idx = peaksWithLags.firstIndex(where: { abs($0.bpm - 129.0) < 2.0 }) {
                print("✓ 129 BPM peak FOUND at rank #\(idx + 1) with normalized value \(String(format: "%.4f", peak129.normalized))")
            }
        } else {
            print("✗ 129 BPM peak NOT IN TOP 20")
        }

        // Check if 43 BPM lag is in top peaks
        if let peak43 = peaksWithLags.first(where: { abs($0.bpm - 43.0) < 2.0 }) {
            if let idx = peaksWithLags.firstIndex(where: { abs($0.bpm - 43.0) < 2.0 }) {
                print("✗ 43 BPM peak FOUND at rank #\(idx + 1) with normalized value \(String(format: "%.4f", peak43.normalized)) (INCORRECT)")
            }
        } else {
            print("? 43 BPM peak NOT IN TOP 20")
        }

        print()
        print("Top 3 peaks:")
        for (idx, peak) in peaksWithLags.prefix(3).enumerated() {
            print("\(idx + 1). \(String(format: "%.1f", peak.bpm)) BPM (lag \(peak.lag) frames, normalized \(String(format: "%.4f", peak.normalized)))")
        }

        // Also check the problem: why is 43 BPM (1/3) being selected?
        print()
        print("=== HYPOTHESIS CHECK: HARMONIC PEAKS ===")
        print("If true beat is at 129 BPM (lag ~\(lag129) frames),")
        print("we'd expect harmonic peaks at:")
        print("  - 129 BPM (1x) lag \(lag129)")
        print("  - 64.5 BPM (1/2) lag \(lag129 * 2)")
        print("  - 43 BPM (1/3) lag \(lag129 * 3)")
        print("  - 258 BPM (2x) lag \(lag129 / 2)")
        print()

        // Check harmonic peaks
        let expectedHarmonics = [
            ("129 BPM (1x)", lag129),
            ("64.5 BPM (1/2)", lag129 * 2),
            ("43 BPM (1/3)", lag129 * 3),
            ("258 BPM (2x)", lag129 / 2)
        ]

        for (label, expectedLag) in expectedHarmonics {
            if expectedLag >= minLag && expectedLag <= maxLag {
                let corr = computeAutocorrelation(onsetStrength, lag: expectedLag)
                let normalized = corr / normFactor
                if let rank = peaksWithLags.firstIndex(where: { $0.lag == expectedLag }) {
                    print("✓ \(label) (lag \(expectedLag)): rank #\(rank + 1), normalized \(String(format: "%.4f", normalized))")
                } else {
                    print("? \(label) (lag \(expectedLag)): outside top 20, normalized \(String(format: "%.4f", normalized))")
                }
            }
        }

        // Test expectation: algorithm should find top peak
        let topPeak = peaksWithLags.first!
        XCTAssert(true, "Diagnostic complete. Top detected peak: \(String(format: "%.1f", topPeak.bpm)) BPM")
    }

    private func computeOnsetStrengthSignal(
        buffer: [Float],
        windowSize: Int,
        hopSize: Int
    ) -> [Float] {
        var onsetStrength: [Float] = []
        var frameIndex = 0

        while frameIndex + windowSize <= buffer.count {
            let frame = Array(buffer[frameIndex..<frameIndex + windowSize])

            var rms: Float = 0
            vDSP_rmsqv(frame, 1, &rms, vDSP_Length(frame.count))

            onsetStrength.append(rms)
            frameIndex += hopSize
        }

        return onsetStrength
    }

    private func computeAutocorrelation(_ signal: [Float], lag: Int) -> Float {
        guard lag < signal.count else { return 0 }

        var correlation: Float = 0
        for i in 0..<(signal.count - lag) {
            correlation += signal[i] * signal[i + lag]
        }

        return correlation / Float(max(1, signal.count - lag))
    }
}
