import Foundation
import MusicCraftCore

/// Ground truth annotation for a test fixture.
enum GroundTruth {
    /// Single chord lasting the entire duration.
    case singleChord(chord: String, confidence: Double = 1.0)

    /// Chord progression with timed transitions.
    case chordProgression(segments: [ChordSegment])

    /// Tempo annotation in beats per minute.
    case tempo(bpm: Int)

    /// Melody notes with timing and pitch.
    case melodyNotes(notes: [NoteAnnotation])

    /// Lyric transcription with timing.
    case lyrics(words: [WordAnnotation])

    /// Composite: chord progression + tempo + contour
    case composite(chords: [ChordSegment], tempo: Int?, contour: [ContourAnnotation]?)

    /// Ground truth chord segment with timing.
    struct ChordSegment {
        let chord: String
        let startTime: TimeInterval
        let endTime: TimeInterval
        let confidence: Double

        var duration: TimeInterval { endTime - startTime }
    }

    /// Ground truth note annotation.
    struct NoteAnnotation {
        let midiNote: Int
        let onsetTime: TimeInterval
        let duration: TimeInterval
        let confidence: Double
    }

    /// Ground truth word annotation (for lyrics).
    struct WordAnnotation {
        let text: String
        let startTime: TimeInterval
        let endTime: TimeInterval
        let confidence: Double

        var duration: TimeInterval { endTime - startTime }
    }

    /// Ground truth contour point (pitch tracking).
    struct ContourAnnotation {
        let pitchSemitoneStep: Int
        let onsetTime: TimeInterval
        let duration: TimeInterval
    }
}
