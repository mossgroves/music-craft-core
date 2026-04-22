import Foundation

/// The seven natural note letter names.
public enum LetterName: Int, CaseIterable {
    case C = 0, D, E, F, G, A, B

    /// Pitch class (0–11) of this natural note.
    public var naturalPitch: Int {
        switch self {
        case .C: return 0
        case .D: return 2
        case .E: return 4
        case .F: return 5
        case .G: return 7
        case .A: return 9
        case .B: return 11
        }
    }

    /// Advance by a number of letter names, wrapping around the octave.
    public func advanced(by steps: Int) -> LetterName {
        LetterName(rawValue: (rawValue + steps) % 7)!
    }
}

/// Accidental modifiers applied to a letter name.
public enum Accidental: Int {
    case doubleFlat = -2
    case flat = -1
    case natural = 0
    case sharp = 1
    case doubleSharp = 2

    /// Symbol for this accidental (𝄫, ♭, "", ♯, 𝄪).
    public var symbol: String {
        switch self {
        case .doubleFlat: return "𝄫"
        case .flat: return "♭"
        case .natural: return ""
        case .sharp: return "♯"
        case .doubleSharp: return "𝄪"
        }
    }
}

/// A note spelled with letter name and accidental (e.g., "B♭", "F♯", "E♯").
/// Spelled notes preserve the diatonic spelling within a key context.
public struct SpelledNote {
    /// The letter name.
    public let letter: LetterName
    /// The accidental.
    public let accidental: Accidental

    public init(letter: LetterName, accidental: Accidental) {
        self.letter = letter
        self.accidental = accidental
    }

    /// Display string (e.g., "B♭", "F♯", "C").
    public var displayString: String {
        let letterStr: String
        switch letter {
        case .C: letterStr = "C"
        case .D: letterStr = "D"
        case .E: letterStr = "E"
        case .F: letterStr = "F"
        case .G: letterStr = "G"
        case .A: letterStr = "A"
        case .B: letterStr = "B"
        }
        return letterStr + accidental.symbol
    }

    /// Pitch class (0–11) that this spelled note represents.
    public var pitchClass: Int {
        (letter.naturalPitch + accidental.rawValue + 12) % 12
    }

    /// The NoteName enum case matching this pitch class.
    public var noteName: NoteName {
        NoteName(rawValue: pitchClass)!
    }
}
