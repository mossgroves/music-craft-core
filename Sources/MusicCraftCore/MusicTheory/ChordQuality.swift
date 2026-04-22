import Foundation

/// The basic chord qualities: major, minor, diminished, augmented, sevenths, sus, and add9.
public enum ChordQuality: String, CaseIterable {
    case major = "major"
    case minor = "minor"
    case diminished = "dim"
    case augmented = "aug"
    case major7 = "maj7"
    case minor7 = "min7"
    case minorMajor7 = "m(maj7)"
    case dominant7 = "7"
    case diminished7 = "dim7"
    case halfDiminished7 = "m7♭5"
    case sus2 = "sus2"
    case sus4 = "sus4"
    case add9 = "add9"
    case minor9 = "min9"
    case major9 = "maj9"
    case power = "5"

    /// Human-readable quality name (e.g., "major seventh").
    public var displayName: String {
        switch self {
        case .major: return "major"
        case .minor: return "minor"
        case .diminished: return "diminished"
        case .augmented: return "augmented"
        case .major7: return "major seventh"
        case .minor7: return "minor seventh"
        case .minorMajor7: return "minor major seventh"
        case .dominant7: return "dominant seventh"
        case .diminished7: return "diminished seventh"
        case .halfDiminished7: return "half-diminished"
        case .sus2: return "suspended second"
        case .sus4: return "suspended fourth"
        case .add9: return "add nine"
        case .minor9: return "minor ninth"
        case .major9: return "major ninth"
        case .power: return "power chord"
        }
    }

    /// Short suffix for display in chord names (e.g., "maj7", "m7", "°", "+").
    public var shortSuffix: String {
        switch self {
        case .major: return ""
        case .minor: return "m"
        case .diminished: return "°"
        case .augmented: return "+"
        case .major7: return "maj7"
        case .minor7: return "m7"
        case .minorMajor7: return "m(maj7)"
        case .dominant7: return "7"
        case .diminished7: return "°7"
        case .halfDiminished7: return "ø7"
        case .sus2: return "sus2"
        case .sus4: return "sus4"
        case .add9: return "add9"
        case .minor9: return "m9"
        case .major9: return "maj9"
        case .power: return "5"
        }
    }

    /// Intervals in semitones from the root, representing the chord's pitch structure.
    public var intervals: [Int] {
        switch self {
        case .major: return [0, 4, 7]
        case .minor: return [0, 3, 7]
        case .diminished: return [0, 3, 6]
        case .augmented: return [0, 4, 8]
        case .major7: return [0, 4, 7, 11]
        case .minor7: return [0, 3, 7, 10]
        case .minorMajor7: return [0, 3, 7, 11]
        case .dominant7: return [0, 4, 7, 10]
        case .diminished7: return [0, 3, 6, 9]
        case .halfDiminished7: return [0, 3, 6, 10]
        case .sus2: return [0, 2, 7]
        case .sus4: return [0, 5, 7]
        case .add9: return [0, 2, 4, 7]
        case .minor9: return [0, 3, 7, 10, 14]
        case .major9: return [0, 4, 7, 11, 14]
        case .power: return [0, 7]
        }
    }

    /// Chroma template: 12-element array with 1.0 where a note class is present.
    public var chromaTemplate: [Double] {
        var template = [Double](repeating: 0.0, count: 12)
        for interval in intervals {
            template[interval % 12] = 1.0
        }
        return template
    }
}
