import Foundation

/// A provider for chord classification using a trained machine learning model.
///
/// Implementations should handle loading and caching of the trained classifier model
/// (e.g., CoreML) and provide a simple interface for classifying chroma vectors.
/// Optional conformance allows graceful degradation: if no classifier is provided,
/// the ChordDetector pipeline falls back to interval-based and template-based matching.
public protocol ChordClassifierProvider {
    /// Classify a normalized 12-element chroma vector.
    /// - Parameters:
    ///   - chroma: A 12-element chroma vector (post-baseline-subtraction)
    /// - Returns: A tuple of (chordName, confidence) if successful, nil if unavailable or on error
    func classifyChroma(_ chroma: [Double]) -> (name: String, confidence: Double)?
}
