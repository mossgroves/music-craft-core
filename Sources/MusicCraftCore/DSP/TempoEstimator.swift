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
