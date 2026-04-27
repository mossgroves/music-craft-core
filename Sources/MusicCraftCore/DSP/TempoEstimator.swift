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
        /// Onset detection window size (samples). Used only if buffer is provided. Default: 2048.
        public let onsetWindowSize: Int

        /// Onset detection hop size (samples). Used only if buffer is provided. Default: 1024.
        public let onsetHopSize: Int

        /// Autocorrelation lag range minimum (ms) for tempo candidates. Default: 300 (~200 BPM).
        public let minTempoMs: Double

        /// Autocorrelation lag range maximum (ms) for tempo candidates. Default: 3000 (~20 BPM).
        public let maxTempoMs: Double

        /// Maximum number of tempo candidates to return. Default: 3.
        public let maxCandidates: Int

        /// Harmonic ratios to consider (e.g., [2, 0.5] includes half-tempo and double-tempo of the dominant).
        /// Default: [1, 2, 0.5, 1.5, 3, 0.33].
        /// Ratios capture tempo ambiguity: double-tempo from syncopation, half-tempo from rubato, triplets.
        public let harmonicRatios: [Double]

        public init(
            onsetWindowSize: Int = 2048,
            onsetHopSize: Int = 1024,
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

        for ratio in configuration.harmonicRatios {
            guard ratio > 0 else { continue }
            if abs(ratio - 1.0) < 1e-6 { continue }

            let harmonicBpm = meanBpm * ratio
            let harmonicConfidence = regularity * (1.0 / ratio)

            allCandidates.append(TempoEstimate(bpm: harmonicBpm, confidence: harmonicConfidence, isHarmonic: true))
        }

        return Array(allCandidates.sorted { $0.confidence > $1.confidence }.prefix(configuration.maxCandidates))
    }

    private static func estimateTempoFromBuffer(
        buffer: [Float],
        sampleRate: Double,
        configuration: Configuration
    ) -> [TempoEstimate] {
        let beats = BeatTracker.detectBeats(
            buffer: buffer,
            sampleRate: sampleRate,
            configuration: BeatTracker.Configuration(
                onsetWindowSize: configuration.onsetWindowSize,
                onsetHopSize: configuration.onsetHopSize
            )
        )

        return estimateTempoFromBeats(beats: beats, configuration: configuration)
    }
}
