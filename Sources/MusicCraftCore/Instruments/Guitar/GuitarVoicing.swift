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

// MARK: - Sounded pitches, bass note, and inversion (slash voicings)

public extension GuitarVoicing {
    /// The MIDI note numbers this voicing sounds, one per ringing (non-muted) string, in string
    /// order (low-E string first). Muted strings (`fret == -1`) are omitted.
    ///
    /// The fret→MIDI rule is chords-db's and is exact: an open string (`0`) sounds the open-string
    /// pitch regardless of `baseFret`; a fretted string sounds `openSemitone + (baseFret - 1) + fret`
    /// (fret values are relative to `baseFret`). Verified against chords-db's own `midi` array across
    /// all 3,283 imported positions, zero mismatches (ChordsDBImportTests, 2026-06-17).
    var soundedMIDINotes: [Int] {
        let open = tuning.semitones
        guard position.frets.count == open.count else { return [] }
        var notes: [Int] = []
        for s in 0..<open.count {
            let fret = position.frets[s]
            if fret < 0 { continue }                       // muted
            if fret == 0 { notes.append(open[s]) }          // open string
            else { notes.append(open[s] + (position.baseFret - 1) + fret) }
        }
        return notes
    }

    /// The bass note of the voicing — the pitch class of its lowest sounding string. Drives the
    /// slash-chord header on the voicing wheel (`Am` vs `Am/C`). Falls back to the chord root if the
    /// voicing has no sounding strings (degenerate; shouldn't occur in real data).
    var bassNote: NoteName {
        guard let lowest = soundedMIDINotes.min() else { return chord.root }
        // MIDI % 12 gives the chromatic pitch class; NoteName is that 0–11 index (C = 0).
        return NoteName(rawValue: ((lowest % 12) + 12) % 12) ?? chord.root
    }

    /// True when the lowest sounding note is NOT the chord root — i.e. this is a slash / inversion
    /// voicing (`Am/C`, `C/E`). chords-db carries these as first-class entries (suffixes like `m/C`,
    /// `/E`); we derive the flag from the actual bass rather than trusting the suffix string.
    var isInversion: Bool { bassNote != chord.root }

    /// Lead-sheet display name: the plain chord name for a root-position voicing (`Am`), or slash
    /// notation when the bass differs from the root (`Am/C`). The wheel header uses this.
    /// Bass is spelled with flats when the chord root is a flat-preferring spelling, else sharps —
    /// so a B♭ inversion reads `B♭/D` and an A inversion reads `A/C♯` (standard convention).
    var slashDisplayName: String {
        guard isInversion else { return chord.displayName }
        let flatRoot = [NoteName.Cs, .Ds, .Fs, .Gs, .As].contains(chord.root)
        let bass = flatRoot ? bassNote.flatName : bassNote.displayName
        return "\(chord.displayName)/\(bass)"
    }
}
