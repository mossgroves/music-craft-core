import Foundation

/// Estimated tempo with confidence and harmonic classification.
/// Produced by TempoEstimator from beat times or audio buffer.
public struct TempoEstimate: Equatable, Hashable, Sendable {
    /// Estimated tempo in beats per minute.
    public let bpm: Double

    /// Confidence score 0.0–1.0 (normalized autocorrelation peak height or inter-beat regularity).
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
