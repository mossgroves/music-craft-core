import Accelerate
import Foundation

/// YIN pitch detection algorithm implemented with Accelerate/vDSP for performance.
/// Reference: de Cheveigné, A., & Kawahara, H. (2002). "YIN, a fundamental frequency estimator for speech and music."
///
/// Includes enhancements to prevent stuck-state after note transitions:
/// - Buffer clearing on silence: clears median filter after consecutive unpitched frames
/// - Pitch jump detection: flushes median filter when pitch changes >3 semitones with high confidence,
///   EXCEPT for octave jumps (12 ±0.5 or 24 ±0.5 semitones) which are fundamental↔harmonic oscillation.
///   Same pattern as the mode stickiness octave jump exemption in AudioEngine.
/// - Confidence-weighted median: high-confidence frames dominate over low-confidence decay frames
final class PitchDetector: @unchecked Sendable {
    struct Result {
        let frequency: Double
        let confidence: Double // 0.0–1.0
        let note: Note?
    }

    private let sampleRate: Double
    private let bufferSize: Int
    private let threshold: Double

    // Pre-allocated buffers
    private var difference: [Float]
    private var cumulativeMean: [Float]

    // Frequency bounds (guitar low E2 ~82Hz to soprano C6 ~1047Hz, with headroom)
    private let minLag: Int
    private let maxLag: Int

    // Confidence-weighted median filter for pitch smoothing.
    // Each entry stores (frequency, confidence) so high-confidence new notes
    // can dominate over low-confidence decay frames.
    private var recentFrequencies: [(frequency: Double, confidence: Double)] = []

    /// When true, bypasses the 3-frame confidence-weighted median filter and returns
    /// raw YIN pitch directly. Used in Notes mode for immediate arpeggio response.
    /// Chord mode and Tuner mode keep median filtering for stability.
    var bypassMedianFilter: Bool = false

    // Consecutive unpitched frame counter for silence detection.
    // After 3+ unpitched frames, the median filter is cleared to prevent
    // stale pitch estimates from biasing the next detection.
    private var consecutiveUnpitchedFrames = 0
    private let unpitchedThresholdForClear = 3

    init(sampleRate: Double = 44100, bufferSize: Int = 8192, threshold: Double = 0.15) {
        self.sampleRate = sampleRate
        self.bufferSize = bufferSize
        self.threshold = threshold

        let halfBuffer = bufferSize / 2
        self.difference = [Float](repeating: 0, count: halfBuffer)
        self.cumulativeMean = [Float](repeating: 0, count: halfBuffer)

        // Lag range: higher lag = lower frequency, lower lag = higher frequency
        // minLag corresponds to highest detectable freq (~4000Hz)
        // maxLag corresponds to lowest detectable freq (~50Hz)
        self.minLag = max(Int(sampleRate / 4000.0), 2)
        self.maxLag = min(Int(sampleRate / 50.0), halfBuffer - 1)
    }

    /// Detect pitch from a buffer of audio samples.
    /// Includes pitch jump detection and silence clearing to prevent stuck-state
    /// when transitioning between notes.
    func detectPitch(buffer: UnsafePointer<Float>, count: Int) -> Result? {
        let effectiveCount = min(count, bufferSize)
        let halfBuffer = effectiveCount / 2

        guard halfBuffer > maxLag else {
            handleUnpitchedFrame()
            return nil
        }

        // Step 1: Compute the difference function using vDSP
        computeDifference(buffer: buffer, count: effectiveCount, halfBuffer: halfBuffer)

        // Step 2: Cumulative mean normalized difference function (CMND)
        computeCumulativeMean(halfBuffer: halfBuffer)

        // Step 3: Absolute threshold — find the first lag where CMND < threshold.
        // Always searches the full lag range (no near-previous-lag optimization)
        // to ensure new pitches are found after silence gaps.
        var bestLag = -1
        for lag in minLag...min(maxLag, halfBuffer - 1) {
            if cumulativeMean[lag] < Float(threshold) {
                bestLag = lag
                // Walk forward to find the local minimum within this dip
                var search = lag + 1
                while search < halfBuffer && cumulativeMean[search] < cumulativeMean[search - 1] {
                    bestLag = search
                    search += 1
                }
                break
            }
        }

        // Fallback: if no value below threshold, find the global minimum
        if bestLag == -1 {
            var minVal: Float = .greatestFiniteMagnitude
            for lag in minLag...min(maxLag, halfBuffer - 1) {
                if cumulativeMean[lag] < minVal {
                    minVal = cumulativeMean[lag]
                    bestLag = lag
                }
            }
            // If global minimum is still too high, no confident pitch
            if minVal > 0.5 {
                handleUnpitchedFrame()
                return nil
            }
        }

        guard bestLag > 0 && bestLag < halfBuffer - 1 else {
            handleUnpitchedFrame()
            return nil
        }

        // Parabolic interpolation for sub-sample accuracy
        let s0 = cumulativeMean[bestLag - 1]
        let s1 = cumulativeMean[bestLag]
        let s2 = cumulativeMean[bestLag + 1]

        let shift: Float
        let denom = 2.0 * s1 - s0 - s2
        if abs(denom) > 1e-10 {
            shift = (s0 - s2) / (2.0 * denom)
        } else {
            shift = 0
        }

        let interpolatedLag = Double(bestLag) + Double(shift)
        let frequency = sampleRate / interpolatedLag

        // Confidence: 1.0 - CMND value at the detected lag
        let confidence = Double(max(0, min(1, 1.0 - s1)))

        guard frequency > 50 && frequency < 4000 else {
            handleUnpitchedFrame()
            return nil
        }

        // Reset unpitched counter — we have a valid pitch
        consecutiveUnpitchedFrames = 0

        // Pitch jump detection: if new pitch differs by >3 semitones from the
        // median filter's last value AND confidence is high, flush the filter.
        // Prevents stale smoothed estimates from dragging on a clearly different note.
        //
        // Octave jump exemption: jumps of 12 ±0.5 or 24 ±0.5 semitones are
        // fundamental↔harmonic oscillation (e.g., B3 247Hz ↔ B4 494Hz). Flushing
        // on these causes a lockup loop — each oscillation clears the median filter
        // before it can accumulate a stable reading. The confidence-weighted median
        // absorbs octave jumps naturally. Same pattern as the mode stickiness octave
        // jump exemption in AudioEngine.
        if confidence > 0.8, let lastEntry = recentFrequencies.last {
            let semitoneDiff = abs(12.0 * log2(frequency / lastEntry.frequency))
            let isNearOctave = abs(semitoneDiff - 12.0) <= 0.5 || abs(semitoneDiff - 24.0) <= 0.5
            if semitoneDiff > 3.0 {
                if isNearOctave {
                    // Skip flush for octave jumps
                } else {
                    recentFrequencies.removeAll()
                }
            }
        }

        // Notes mode: bypass median filter for immediate arpeggio response.
        // Chord/Tuner mode: use confidence-weighted median for stability.
        let smoothedFrequency: Double
        if bypassMedianFilter {
            smoothedFrequency = frequency
        } else {
            smoothedFrequency = medianSmooth(frequency, confidence: confidence)
        }
        let note = MusicTheory.noteFromFrequency(smoothedFrequency)

        return Result(
            frequency: smoothedFrequency,
            confidence: confidence,
            note: note
        )
    }

    /// Reset pitch smoothing state. Called when listening starts/stops or mode changes.
    func reset() {
        recentFrequencies.removeAll()
        consecutiveUnpitchedFrames = 0
    }

    /// Track unpitched frames and clear median filter after sustained silence.
    /// Prevents stale pitch estimates from biasing the next detection after a note decays.
    private func handleUnpitchedFrame() {
        consecutiveUnpitchedFrames += 1
        if consecutiveUnpitchedFrames == unpitchedThresholdForClear && !recentFrequencies.isEmpty {
            recentFrequencies.removeAll()
        }
    }

    /// Confidence-weighted 3-frame median filter for pitch smoothing.
    /// When the newest frame has confidence > 2x the median confidence of buffered frames,
    /// it gets dominant weight (replaces all entries). This ensures a strong new note's attack
    /// is not dragged by low-confidence frames from the previous note's decay.
    private func medianSmooth(_ frequency: Double, confidence: Double) -> Double {
        // If newest frame is much more confident than the buffer, give it dominant weight
        if !recentFrequencies.isEmpty {
            let medianConfidence = recentFrequencies.map(\.confidence).sorted()[recentFrequencies.count / 2]
            if confidence > medianConfidence * 2.0 {
                // Dominant frame — replace entire buffer
                recentFrequencies = [(frequency, confidence)]
                return frequency
            }
        }

        recentFrequencies.append((frequency, confidence))
        if recentFrequencies.count > 3 {
            recentFrequencies.removeFirst()
        }
        let sorted = recentFrequencies.sorted { $0.frequency < $1.frequency }
        return sorted[sorted.count / 2].frequency
    }

    // MARK: - YIN Internals

    /// Compute the YIN difference function using vDSP for the inner product
    private func computeDifference(buffer: UnsafePointer<Float>, count: Int, halfBuffer: Int) {
        // d(tau) = sum_{j=0}^{W-1} (x[j] - x[j+tau])^2
        // Expanded: d(tau) = r_x(0, W) + r_x(tau, W) - 2 * crossCorr(tau, W)
        // Use fixed window W = halfBuffer for all lags (standard YIN).
        // Safe because buffer has count >= 2*halfBuffer samples.

        let W = vDSP_Length(halfBuffer)

        // Energy of original window (constant across all lags)
        var energyOrig: Float = 0
        vDSP_dotpr(buffer, 1, buffer, 1, &energyOrig, W)

        difference[0] = 0

        for tau in 1..<halfBuffer {
            // Cross-correlation at this lag
            var crossCorr: Float = 0
            vDSP_dotpr(buffer, 1, buffer + tau, 1, &crossCorr, W)

            // Energy of shifted window
            var energyTau: Float = 0
            vDSP_dotpr(buffer + tau, 1, buffer + tau, 1, &energyTau, W)

            difference[tau] = energyOrig + energyTau - 2.0 * crossCorr
        }
    }

    /// Cumulative mean normalized difference function
    private func computeCumulativeMean(halfBuffer: Int) {
        cumulativeMean[0] = 1.0
        var runningSum: Float = 0

        for tau in 1..<halfBuffer {
            runningSum += difference[tau]
            if runningSum > 0 {
                cumulativeMean[tau] = difference[tau] * Float(tau) / runningSum
            } else {
                cumulativeMean[tau] = 1.0
            }
        }
    }
}
