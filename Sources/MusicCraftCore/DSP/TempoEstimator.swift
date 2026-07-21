import Accelerate
import Foundation

/// Tempo estimation from beat times or audio buffer.
/// Estimates one or more tempo candidates with confidence scores.
public enum TempoEstimator {
    /// Estimate tempo from beat times or from an audio buffer directly.
    /// If beats are provided, compute tempo from inter-beat intervals.
    /// If buffer is provided, detect onsets and estimate tempo from the onset strength signal.
    ///
    /// - Parameters:
    ///   - beats: Pre-detected beat times in seconds. If provided, buffer is ignored.
    ///   - buffer: Audio buffer (used if beats is nil).
    ///   - sampleRate: Sample rate (required if buffer is provided).
    ///   - configuration: Optional tuning.
    /// - Returns: Array of tempo candidates ranked by confidence. Empty if no tempos detected.
    public static func estimateTempo(
        beats: [TimeInterval]? = nil,
        buffer: [Float]? = nil,
        sampleRate: Double? = nil,
        configuration: Configuration = .default
    ) -> [TempoEstimate] {
        if let beats = beats, !beats.isEmpty {
            return estimateTempoFromBeats(beats: beats, configuration: configuration)
        }

        if let buffer = buffer, let sampleRate = sampleRate, !buffer.isEmpty {
            return estimateTempoFromBuffer(buffer: buffer, sampleRate: sampleRate, configuration: configuration)
        }

        return []
    }

    /// Tuning parameters for tempo estimation.
    public struct Configuration: Equatable, Hashable, Sendable {
        /// STFT window size (samples) for the spectral-flux onset detector used by the buffer path.
        /// Default lowered to 1024 in 0.0.11 to match per-frame onset granularity.
        public let onsetWindowSize: Int

        /// STFT hop size (samples) for the spectral-flux onset detector. Default 512 (50% overlap).
        public let onsetHopSize: Int

        /// Minimum inter-onset interval (ms) for the tempo histogram path. Default: 300 (~200 BPM).
        public let minTempoMs: Double

        /// Maximum inter-onset interval (ms) for the tempo histogram path. Default: 3000 (~20 BPM).
        public let maxTempoMs: Double

        /// Maximum number of tempo candidates to return. Default: 3.
        public let maxCandidates: Int

        /// Harmonic ratios used by the `estimateTempo(beats:)` JAMS-fed path (preserved for
        /// backward compatibility). The buffer path generates 2x and 0.5x octave candidates
        /// internally during histogram construction; this field is ignored on the buffer path.
        public let harmonicRatios: [Double]

        public init(
            onsetWindowSize: Int = 1024,
            onsetHopSize: Int = 512,
            minTempoMs: Double = 300,
            maxTempoMs: Double = 3000,
            maxCandidates: Int = 3,
            harmonicRatios: [Double] = [1, 2, 0.5, 1.5, 3, 0.33]
        ) {
            self.onsetWindowSize = onsetWindowSize
            self.onsetHopSize = onsetHopSize
            self.minTempoMs = minTempoMs
            self.maxTempoMs = maxTempoMs
            self.maxCandidates = maxCandidates
            self.harmonicRatios = harmonicRatios
        }

        public static let `default` = Configuration()
    }

    /// Estimate tempo from NOTE ONSETS — the note-native path (2026-07-21).
    ///
    /// Since 0.1.0 the engine is note-native (chords/key/contour all derive from Basic Pitch's
    /// note events); tempo was the last subsystem still fed by the spectral-flux front-end,
    /// whose known weakness on acoustic guitar is documented in TASKS (all five GuitarSet
    /// fixtures locked to 1/3 of ground truth; consumers saw mostly-abstaining tempo on real
    /// takes). Basic Pitch's onsets are far cleaner rhythmic evidence on guitar than raw flux —
    /// this entry feeds them into the SAME TempoHistogram the buffer path uses.
    ///
    /// One preparation step matters: **cluster collapsing.** A strummed chord is ONE rhythmic
    /// event played across many strings — its 3–6 note onsets land within a few tens of ms, and
    /// left as-is each would vote an absurd micro-IOI. Onsets within `clusterWindow` collapse to
    /// their first member before the histogram sees them (fingerpicked lines, whose notes spread
    /// wider than the window, pass through untouched).
    ///
    /// Returns [] below `minEvents` collapsed events — a handful of notes is not a pulse claim.
    ///
    /// CONFIDENCE SEMANTICS (the dead-axis root cause, measured 2026-07-21): the histogram's
    /// raw peak-mass share is structurally tiny — on PERFECT metronomic input it caps ≈0.22
    /// (each IOI's vote splits across octave bins and 3-bin smoothing), so a consumer gate
    /// calibrated to the beats path's regularity scale (~0.9 on steady input) could never pass.
    /// This path therefore reports **IOI consistency** instead: the fraction of collapsed
    /// inter-onset intervals that agree with the candidate's beat period at the 1x, 2x, or 0.5x
    /// level within ±8%. Steady playing → ~1.0; loose but real pulse → mid; rubato → low.
    /// Candidates are RANKED by that consistency too (histogram weight as tie-break), which
    /// demotes spurious near-miss peaks and sub-beat locks the raw histogram can rank first —
    /// the exact failure mode the flux path showed on GuitarSet (1/3-tempo lock).
    public static func estimateTempo(
        noteOnsets: [TimeInterval],
        configuration: Configuration = .default,
        clusterWindow: TimeInterval = 0.05,
        minEvents: Int = 6
    ) -> [TempoEstimate] {
        let events = collapseClusters(noteOnsets.sorted(), window: clusterWindow)
        guard events.count >= minEvents else { return [] }

        let minBpm = max(40, Int((60_000.0 / configuration.maxTempoMs).rounded(.down)))
        let maxBpm = min(200, Int((60_000.0 / configuration.minTempoMs).rounded(.up)))

        // Wider smoothing than the buffer path (5 vs 3): human timing + Basic Pitch's ~11ms
        // onset quantization scatter votes across neighboring 1-BPM bins.
        let peaks = TempoHistogram.estimate(
            onsets: events,
            minBpm: minBpm,
            maxBpm: maxBpm,
            smoothingWindow: 5,
            maxCandidates: max(3, configuration.maxCandidates)
        )
        guard !peaks.isEmpty else { return [] }

        var iois: [TimeInterval] = []
        for i in 1..<events.count where events[i] - events[i - 1] > 0 {
            iois.append(events[i] - events[i - 1])
        }
        guard !iois.isEmpty else { return [] }

        /// Fraction of IOIs consistent with `bpm` at the beat, double, or half level (±8% — wide
        /// enough for human jitter, tight enough to reject near-miss tempi like 160 vs true 180).
        func consistency(_ bpm: Double) -> Double {
            let period: Double = 60.0 / bpm
            let levels: [Double] = [period, period * 2.0, period * 0.5]
            var matched = 0
            for ioi in iois {
                for level in levels where abs(ioi - level) <= 0.08 * level {
                    matched += 1
                    break
                }
            }
            return Double(matched) / Double(iois.count)
        }

        var scored: [(bpm: Double, consistency: Double, weight: Double)] = []
        for peak in peaks {
            scored.append((bpm: peak.bpm, consistency: consistency(peak.bpm), weight: peak.confidence))
        }
        scored.sort { a, b in
            a.consistency == b.consistency ? a.weight > b.weight : a.consistency > b.consistency
        }
        scored = Array(scored.prefix(configuration.maxCandidates))

        let primaryBpm = scored.first!.bpm
        return scored.enumerated().map { idx, entry in
            let isHarmonic = idx > 0 && (
                abs(entry.bpm - primaryBpm * 2.0) < 1.5
                || abs(entry.bpm - primaryBpm * 0.5) < 1.5
            )
            return TempoEstimate(bpm: entry.bpm, confidence: entry.consistency, isHarmonic: isHarmonic)
        }
    }

    /// Collapse onsets that fall within `window` of the previous kept event into one (keeping
    /// the cluster's FIRST onset — the moment the gesture landed). Internal for tests.
    static func collapseClusters(_ sortedOnsets: [TimeInterval], window: TimeInterval) -> [TimeInterval] {
        guard !sortedOnsets.isEmpty else { return [] }
        var events: [TimeInterval] = [sortedOnsets[0]]
        for onset in sortedOnsets.dropFirst() where onset - events[events.count - 1] > window {
            events.append(onset)
        }
        return events
    }

    private static func estimateTempoFromBeats(beats: [TimeInterval], configuration: Configuration) -> [TempoEstimate] {
        guard beats.count >= 2 else { return [] }

        var interBeatIntervals: [TimeInterval] = []
        for i in 1..<beats.count {
            interBeatIntervals.append(beats[i] - beats[i - 1])
        }

        guard !interBeatIntervals.isEmpty else { return [] }

        let meanIbi = interBeatIntervals.reduce(0, +) / Double(interBeatIntervals.count)
        let variance = interBeatIntervals.map { pow($0 - meanIbi, 2) }.reduce(0, +) / Double(interBeatIntervals.count)
        let stdDev = sqrt(variance)
        let regularity = max(0, 1.0 - (stdDev / (meanIbi + 1e-10)))

        let meanBpm = 60.0 / meanIbi
        let baseTempoEstimate = TempoEstimate(bpm: meanBpm, confidence: regularity, isHarmonic: false)

        var allCandidates: [TempoEstimate] = [baseTempoEstimate]

        // Harmonics get a fixed octave-error penalty so they always rank below the base when
        // beats are reasonably regular. Prior 0.0.10 logic used `regularity * (1.0 / ratio)`,
        // which gave a 0.5x harmonic *twice* the confidence of the base and caused
        // half-tempo to be reported as primary on regular beat streams (Phase 3.2 GuitarSet
        // accuracy was 0% because of this — separate from the buffer-path 1/3-bug).
        let harmonicPenalty = 0.5
        for ratio in configuration.harmonicRatios {
            guard ratio > 0 else { continue }
            if abs(ratio - 1.0) < 1e-6 { continue }

            let harmonicBpm = meanBpm * ratio
            let harmonicConfidence = regularity * harmonicPenalty

            allCandidates.append(TempoEstimate(bpm: harmonicBpm, confidence: harmonicConfidence, isHarmonic: true))
        }

        return Array(allCandidates.sorted { $0.confidence > $1.confidence }.prefix(configuration.maxCandidates))
    }

    private static func estimateTempoFromBuffer(
        buffer: [Float],
        sampleRate: Double,
        configuration: Configuration
    ) -> [TempoEstimate] {
        let onsets = SpectralFluxOnsetDetector.detectOnsets(
            buffer: buffer,
            sampleRate: sampleRate,
            windowSize: configuration.onsetWindowSize,
            hopSize: configuration.onsetHopSize
        )

        let minBpm = max(40, Int((60_000.0 / configuration.maxTempoMs).rounded(.down)))
        let maxBpm = min(200, Int((60_000.0 / configuration.minTempoMs).rounded(.up)))

        let peaks = TempoHistogram.estimate(
            onsets: onsets,
            minBpm: minBpm,
            maxBpm: maxBpm,
            smoothingWindow: 3,
            maxCandidates: configuration.maxCandidates
        )

        guard !peaks.isEmpty else { return [] }
        let primaryBpm = peaks[0].bpm

        return peaks.enumerated().map { idx, peak in
            let isHarmonic = idx > 0 && (
                abs(peak.bpm - primaryBpm * 2.0) < 1.5
                || abs(peak.bpm - primaryBpm * 0.5) < 1.5
            )
            return TempoEstimate(bpm: peak.bpm, confidence: peak.confidence, isHarmonic: isHarmonic)
        }
    }
}
