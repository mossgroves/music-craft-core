import Foundation

/// A timestamped word or phrase token from speech transcription.
/// Produced by LyricsExtractor.transcribe for alignment with chord and melody timelines.
public struct TranscribedToken: Equatable, Hashable, Sendable {
    /// The recognized word or phrase.
    public let text: String

    /// Onset time in seconds from the start of the buffer.
    public let onsetTime: TimeInterval

    /// Duration of the token in seconds.
    public let duration: TimeInterval

    /// Confidence score 0.0–1.0. Present only if Configuration.includeConfidence = true (iOS 26+ SpeechAnalyzer).
    /// iOS 17 SFSpeechRecognizer does not expose per-token confidence and always returns nil.
    public let confidence: Double?

    /// Derived: offset time in seconds (onsetTime + duration).
    public var offsetTime: TimeInterval { onsetTime + duration }

    public init(
        text: String,
        onsetTime: TimeInterval,
        duration: TimeInterval,
        confidence: Double? = nil
    ) {
        self.text = text
        self.onsetTime = onsetTime
        self.duration = duration
        self.confidence = confidence
    }
}
