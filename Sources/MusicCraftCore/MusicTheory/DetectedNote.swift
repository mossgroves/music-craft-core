import Foundation

/// A single raw monophonic note event detected from audio.
///
/// DetectedNote is a lower-level representation than ContourNote:
/// these are individual note events as they emerge from the pitch-tracking + onset pipeline,
/// before relative-pitch differencing produces the contour.
/// Consumed by MelodyKeyInference and composed into contours by the offline analysis pipeline.
public struct DetectedNote: Equatable, Hashable, Sendable {
    /// MIDI note number (60 = middle C, 69 = A4 at 440 Hz).
    public let midiNote: Int

    /// Onset time in seconds from the start of the analyzed buffer.
    public let onsetTime: TimeInterval

    /// Note duration in seconds.
    public let duration: TimeInterval

    /// Detection confidence from the pitch tracker (0.0–1.0).
    public let confidence: Double

    /// Pitch class (0–11; 0 = C, 1 = C♯/D♭, ..., 11 = B).
    /// Computed from midiNote: `midiNote % 12`.
    public var pitchClass: Int {
        midiNote % 12
    }

    /// Creates a DetectedNote with timing, pitch, and confidence information.
    ///
    /// - Parameters:
    ///   - midiNote: MIDI note number (0–127).
    ///   - onsetTime: Onset time in seconds from buffer start.
    ///   - duration: Note duration in seconds.
    ///   - confidence: Detection confidence (0.0–1.0) from pitch tracker.
    public init(
        midiNote: Int,
        onsetTime: TimeInterval,
        duration: TimeInterval,
        confidence: Double
    ) {
        self.midiNote = midiNote
        self.onsetTime = onsetTime
        self.duration = duration
        self.confidence = confidence
    }
}
