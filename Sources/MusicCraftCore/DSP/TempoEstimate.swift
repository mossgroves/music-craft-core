import Foundation

/// Estimated tempo with confidence and harmonic classification.
/// Produced by TempoEstimator from beat times or audio buffer.
public struct TempoEstimate: Equatable, Hashable, Sendable {
    /// Estimated tempo in beats per minute.
    public let bpm: Double

    /// Confidence in `[0, 1]`.
    ///
    /// As of 0.0.11 (buffer path): fraction of inter-onset-interval evidence in the tempo
    /// histogram supporting this BPM. Higher values indicate more onsets aligned to this BPM.
    /// On the `estimateTempo(beats:)` path: inter-beat-interval regularity (1 − std/mean).
    ///
    /// Consumers displaying tempo to end users should gate on `confidence >= 0.3` to suppress
    /// unreliable estimates on low-rhythm material (e.g., monophonic vocals without clear pulse).
    public let confidence: Double

    /// Whether this tempo is a harmonic of a lower-frequency candidate (e.g., double-tempo).
    /// Allows consumers to group related tempos when analyzing ambiguous signals.
    public let isHarmonic: Bool

    public init(bpm: Double, confidence: Double, isHarmonic: Bool = false) {
        self.bpm = bpm
        self.confidence = confidence
        self.isHarmonic = isHarmonic
    }
}
