import Foundation

/// A noise baseline chroma vector computed from genuine silence frames.
///
/// Used by NoiseCalibrator and consumed by ChordDetection for noise subtraction.
/// The baseline represents the average spectral content of background noise, allowing
/// downstream algorithms to subtract it from signal chroma vectors.
public struct NoiseBaseline: Equatable, Hashable, Sendable {
    /// 12-element chroma vector: per-pitch-class energy in silence.
    public let chroma: [Double]

    /// Number of silence frames averaged to produce the baseline.
    public let frameCount: Int

    /// Total chroma energy (sum of all 12 elements). Used for contamination diagnostics.
    public var totalEnergy: Double {
        chroma.reduce(0, +)
    }

    /// Creates a NoiseBaseline from a chroma vector and frame count.
    ///
    /// - Parameters:
    ///   - chroma: 12-element pitch-class energy vector from silence frames.
    ///   - frameCount: Number of frames averaged to produce the baseline.
    public init(chroma: [Double], frameCount: Int) {
        self.chroma = chroma
        self.frameCount = frameCount
    }
}
