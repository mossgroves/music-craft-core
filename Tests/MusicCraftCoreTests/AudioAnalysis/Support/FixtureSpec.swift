import Foundation

/// Specification for a single-chord fixture.
struct ChordFixtureSpec {
    let chord: String           // e.g. "Am", "C", "G7"
    let voicing: GuitarVoicing
    let duration: TimeInterval
    let velocity: UInt8
    let attackOffset: TimeInterval

    init(
        chord: String,
        voicing: GuitarVoicing,
        duration: TimeInterval = 4.0,
        velocity: UInt8 = 100,
        attackOffset: TimeInterval = 0.0
    ) {
        self.chord = chord
        self.voicing = voicing
        self.duration = duration
        self.velocity = velocity
        self.attackOffset = attackOffset
    }
}

/// Specification for a chord progression fixture.
struct ProgressionFixtureSpec {
    let name: String                        // e.g. "I-IV-V-I in C"
    let chords: [(chord: String, duration: TimeInterval)]  // Chord + time
    let tempo: Double                       // BPM
    let voicing: GuitarVoicing
    let velocity: UInt8
    let key: String                         // Tonic note for Roman numeral mapping

    init(
        name: String,
        chords: [(String, TimeInterval)],
        tempo: Double,
        voicing: GuitarVoicing,
        velocity: UInt8 = 100,
        key: String
    ) {
        self.name = name
        self.chords = chords
        self.tempo = tempo
        self.voicing = voicing
        self.velocity = velocity
        self.key = key
    }
}

/// Specification for a scale or chromatic fixture.
struct ScaleFixtureSpec {
    let name: String
    let notes: [UInt8]              // MIDI note numbers
    let noteDuration: TimeInterval
    let velocity: UInt8
    let octaveStart: UInt8          // Starting octave for scale labels

    init(
        name: String,
        notes: [UInt8],
        noteDuration: TimeInterval = 0.5,
        velocity: UInt8 = 100,
        octaveStart: UInt8 = 4
    ) {
        self.name = name
        self.notes = notes
        self.noteDuration = noteDuration
        self.velocity = velocity
        self.octaveStart = octaveStart
    }
}
