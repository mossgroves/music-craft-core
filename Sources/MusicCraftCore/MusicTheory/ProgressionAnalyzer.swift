import Foundation

/// A stateless namespace for chord progression analysis: key inference and pattern recognition.
public enum ProgressionAnalyzer {
    /// Infers the most likely musical key for a chord progression.
    /// Returns nil if the progression is too short or ambiguous to determine a key.
    /// - Parameter chords: A sequence of chords to analyze.
    /// - Returns: The inferred MusicalKey, or nil if inference fails.
    public static func inferKey(from chords: [Chord]) -> MusicalKey? {
        ProgressionAnalyzer_KeyInference.inferKey(from: chords)
    }

    /// Recognizes a known progression pattern within a chord sequence in a given key.
    /// - Parameter progression: A sequence of chords to match against the pattern library.
    /// - Parameter key: The musical key context for interpreting the chords as Roman numerals.
    /// - Returns: A RecognizedPattern if a match is found (exact or fuzzy), otherwise nil.
    public static func recognizePattern(progression: [Chord], in key: MusicalKey) -> RecognizedPattern? {
        ProgressionAnalyzer_PatternRecognition.recognizePattern(progression: progression, in: key)
    }
}
