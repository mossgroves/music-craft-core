import Foundation

/// The mode (major or minor) of a musical key.
public enum KeyMode: Equatable, Hashable, Sendable {
    case major
    case minor
}

/// A musical key, defined by a root note and mode.
public struct MusicalKey: Equatable, Hashable, Sendable {
    /// Root note of the key.
    public let root: NoteName
    /// Mode (major or minor).
    public let mode: KeyMode

    public init(root: NoteName, mode: KeyMode) {
        self.root = root
        self.mode = mode
    }

    /// Display name (e.g., "C major", "A minor").
    public var displayName: String {
        switch mode {
        case .major: return "\(root.displayName) major"
        case .minor: return "\(root.displayName) minor"
        }
    }

    /// Diatonic chord qualities for each scale degree (1-7).
    public var diatonicQualities: [ChordQuality] {
        switch mode {
        case .major:
            return [.major, .minor, .minor, .major, .major, .minor, .diminished]
        case .minor:
            return [.minor, .diminished, .major, .minor, .minor, .major, .major]
        }
    }

    /// Scale degree intervals in semitones (0–11) for each scale degree (1-7).
    public var scaleIntervals: [Int] {
        switch mode {
        case .major: return [0, 2, 4, 5, 7, 9, 11]
        case .minor: return [0, 2, 3, 5, 7, 8, 10]
        }
    }

    /// Shared logic for deriving Roman numeral data from a chord.
    private func romanNumeralData(for chord: Chord) -> (degree: Int, quality: RomanNumeral.Quality)? {
        let semitones = ((chord.root.rawValue - root.rawValue) + 12) % 12

        guard let degreeIndex = scaleIntervals.firstIndex(of: semitones) else {
            return nil
        }

        let quality: RomanNumeral.Quality
        switch chord.quality {
        case .minor, .minor7, .minor9:
            quality = .minor
        case .diminished, .diminished7, .halfDiminished7:
            quality = .diminished
        case .augmented:
            quality = .augmented
        case .dominant7:
            quality = .dominant7
        case .major7:
            quality = .major7
        default:
            quality = .major
        }

        return (degreeIndex + 1, quality)
    }

    /// Roman numeral representation of a chord in this key, or nil if the chord is not diatonic.
    public func romanNumeral(for chord: Chord) -> String? {
        guard let data = romanNumeralData(for: chord) else {
            return nil
        }

        let numerals = ["I", "II", "III", "IV", "V", "VI", "VII"]
        let numeral = numerals[data.degree - 1]

        switch data.quality {
        case .minor:
            return numeral.lowercased()
        case .diminished:
            return numeral.lowercased() + "°"
        case .augmented:
            return numeral + "+"
        case .dominant7:
            return numeral + "7"
        case .major7:
            return numeral + "Δ7"
        case .minor7:
            return numeral.lowercased() + "7"
        case .halfDiminished7:
            return numeral.lowercased() + "ø7"
        case .diminished7:
            return numeral.lowercased() + "°7"
        case .major:
            return numeral
        }
    }

    /// Returns a typed RomanNumeral for a chord in this key, or nil if the chord is not diatonic.
    /// Mirrors romanNumeral(for:) in behavior: both return nil for identical inputs, and displayString
    /// of the returned RomanNumeral equals the String returned by romanNumeral(for:).
    public func romanNumeralTyped(for chord: Chord) -> RomanNumeral? {
        guard let data = romanNumeralData(for: chord) else {
            return nil
        }

        let degree = RomanNumeral.Degree(rawValue: data.degree)!
        return RomanNumeral(degree: degree, accidental: .natural, quality: data.quality)
    }
}
