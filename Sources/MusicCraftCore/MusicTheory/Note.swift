import Foundation

/// A note with frequency and pitch information. Includes cents deviation for microtonal accuracy.
public struct Note: Equatable {
    /// The note name (C through B).
    public let name: NoteName
    /// Octave number (MIDI convention: -1 for sub-bass, 0-8 for audible range, etc.).
    public let octave: Int
    /// Frequency in Hz.
    public let frequency: Double
    /// Cents deviation from the nearest semitone (-50 to +50, where 100 cents = 1 semitone).
    public let centsDeviation: Double

    /// MIDI note number corresponding to this note and octave.
    public var midiNumber: Int {
        return (octave + 1) * 12 + name.rawValue
    }

    /// Display string (e.g., "C♯4").
    public var displayString: String {
        return "\(name.displayName)\(octave)"
    }

    public init(name: NoteName, octave: Int, frequency: Double, centsDeviation: Double) {
        self.name = name
        self.octave = octave
        self.frequency = frequency
        self.centsDeviation = centsDeviation
    }
}

/// A melody note without frequency or cents information; pitch only.
public struct MelodyNote: Equatable {
    /// The note name.
    public let name: NoteName
    /// Octave number.
    public let octave: Int

    /// Display string (e.g., "D♯3").
    public var displayString: String {
        return "\(name.displayName)\(octave)"
    }

    public init(name: NoteName, octave: Int) {
        self.name = name
        self.octave = octave
    }

    public static func == (lhs: MelodyNote, rhs: MelodyNote) -> Bool {
        lhs.name == rhs.name && lhs.octave == rhs.octave
    }
}

/// Music theory utilities for frequency and MIDI conversions.
public enum MusicTheory {
    /// A4 reference frequency in Hz.
    public static let referenceA4: Double = 440.0
    /// MIDI note number for A4.
    public static let a4MidiNumber: Int = 69

    /// Convert a frequency to the nearest note with cents deviation.
    /// Returns nil if the frequency is outside the audible range (20–10000 Hz).
    public static func noteFromFrequency(_ frequency: Double) -> Note? {
        guard frequency > 20 && frequency < 10000 else { return nil }

        let midiFloat = 12.0 * log2(frequency / referenceA4) + Double(a4MidiNumber)
        let midiNumber = Int(round(midiFloat))
        let cents = (midiFloat - Double(midiNumber)) * 100.0

        let noteIndex = ((midiNumber % 12) + 12) % 12
        let octave = (midiNumber / 12) - 1

        guard let noteName = NoteName(rawValue: noteIndex) else { return nil }

        return Note(
            name: noteName,
            octave: octave,
            frequency: frequency,
            centsDeviation: cents
        )
    }

    /// Frequency for a given MIDI note number.
    public static func frequencyForMidi(_ midi: Int) -> Double {
        return referenceA4 * pow(2.0, Double(midi - a4MidiNumber) / 12.0)
    }

    /// Frequency for a specific note name and octave.
    public static func frequency(for name: NoteName, octave: Int) -> Double {
        let midi = (octave + 1) * 12 + name.rawValue
        return frequencyForMidi(midi)
    }
}
