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

    /// TRUE WHEN THE RECOGNIZER BEGAN A NEW SEGMENT AT THIS TOKEN (0.1.11).
    ///
    /// Whisper decodes in segments and reports where each one begins; Apple's transcriber emits
    /// its own results in pieces the same way. That boundary is a real signal about PHRASING —
    /// the recognizer heard the utterance restart — and MCC used to drop it on the floor when
    /// flattening segments into one token stream, leaving consumers to re-derive phrasing from
    /// silence gaps alone.
    ///
    /// It is a HINT, not a line break: recognizers segment for their own reasons (a decode
    /// window filling, a long silence, a confidence collapse), so a consumer should weigh it
    /// beside its own evidence rather than obey it. Sanctuary uses it as one candidate among
    /// several when deciding where a lyric's lines fall.
    ///
    /// Defaults to false, so every existing caller and every stored token stream reads exactly
    /// as it did before.
    public let startsSegment: Bool

    /// Derived: offset time in seconds (onsetTime + duration).
    public var offsetTime: TimeInterval { onsetTime + duration }

    public init(
        text: String,
        onsetTime: TimeInterval,
        duration: TimeInterval,
        confidence: Double? = nil,
        startsSegment: Bool = false
    ) {
        self.text = text
        self.onsetTime = onsetTime
        self.duration = duration
        self.confidence = confidence
        self.startsSegment = startsSegment
    }
}
