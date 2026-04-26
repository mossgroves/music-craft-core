import Foundation

/// A single note in a melodic contour with absolute timing and relative pitch direction.
///
/// Combines symbolic relative pitch (Parsons code and signed semitone step) with absolute timing.
/// Used to represent the pitch trajectory and timing of monophonic melodic content extracted
/// from audio via pitch tracking and note event detection.
///
/// **First note convention:** For the first note in a contour (no predecessor note),
/// `pitchSemitoneStep = 0` and `parsonsCode = .repeat_`. This convention distinguishes
/// the "no predecessor" case from a true repeated note and is applied consistently
/// throughout MCC's contour pipeline.
public struct ContourNote: Equatable, Hashable, Sendable {
    /// Signed semitone step from the previous note to this note.
    /// Zero for the first note (no predecessor).
    /// Positive values indicate upward motion; negative values indicate downward motion.
    public let pitchSemitoneStep: Int

    /// Symbolic direction — Up, Down, or Repeat.
    /// For non-first notes, equivalent to the sign of `pitchSemitoneStep`.
    /// For the first note, always `.repeat_` (per convention).
    public let parsonsCode: ParsonsCode

    /// Onset time in seconds from the start of the analyzed buffer.
    public let onsetTime: TimeInterval

    /// Note duration in seconds.
    public let duration: TimeInterval

    /// Creates a ContourNote with timing and relative pitch information.
    ///
    /// - Parameters:
    ///   - pitchSemitoneStep: Signed semitone step from previous note (0 for first note).
    ///   - parsonsCode: Symbolic direction code.
    ///   - onsetTime: Onset time in seconds from buffer start.
    ///   - duration: Note duration in seconds.
    public init(
        pitchSemitoneStep: Int,
        parsonsCode: ParsonsCode,
        onsetTime: TimeInterval,
        duration: TimeInterval
    ) {
        self.pitchSemitoneStep = pitchSemitoneStep
        self.parsonsCode = parsonsCode
        self.onsetTime = onsetTime
        self.duration = duration
    }
}
