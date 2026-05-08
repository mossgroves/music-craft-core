import Foundation

/// A chord voicing on a specific guitar tuning.
public struct GuitarVoicing: Equatable, Hashable, Sendable, Identifiable {
    /// Unique identifier
    public let id: UUID

    /// The chord this voicing represents
    public let chord: Chord

    /// The tuning this voicing is designed for
    public let tuning: GuitarTuning

    /// The fretboard position
    public let position: VoicingPosition

    /// Computed display name describing the voicing position
    public var displayName: String {
        let posDesc = position.baseFret == 1 ? "open" : "fret \(position.baseFret)"
        return "\(chord.displayName) — \(posDesc)"
    }

    public init(id: UUID = UUID(), chord: Chord, tuning: GuitarTuning, position: VoicingPosition) {
        self.id = id
        self.chord = chord
        self.tuning = tuning
        self.position = position
    }
}
