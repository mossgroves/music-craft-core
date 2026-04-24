import Foundation

/// A Roman numeral representation of a chord scale degree with accidental and quality modifications.
public struct RomanNumeral: Equatable, Hashable, Sendable {
    /// Scale degree (1–7).
    public enum Degree: Int, Equatable, Hashable, Sendable {
        case one = 1
        case two = 2
        case three = 3
        case four = 4
        case five = 5
        case six = 6
        case seven = 7
    }

    /// Accidental modifier on the degree.
    public enum Accidental: Equatable, Hashable, Sendable {
        case natural
        case flat
        case sharp
    }

    /// Chord quality relative to diatonic form.
    public enum Quality: Equatable, Hashable, Sendable {
        case major
        case minor
        case diminished
        case augmented
        case dominant7
        case major7
        case minor7
        case halfDiminished7
        case diminished7
    }

    public let degree: Degree
    public let accidental: Accidental
    public let quality: Quality

    /// Initializes a RomanNumeral with degree, accidental (default natural), and quality (default major).
    public init(degree: Degree, accidental: Accidental = .natural, quality: Quality = .major) {
        self.degree = degree
        self.accidental = accidental
        self.quality = quality
    }

    /// Produces the canonical display string for this Roman numeral.
    /// Examples: "I", "i", "♭VII", "iiø7", "VΔ7", "V+", "vii°", "V7", "ii7", "♭III", "♯IV".
    public var displayString: String {
        let romanNumerals = ["I", "II", "III", "IV", "V", "VI", "VII"]
        var numeral = romanNumerals[degree.rawValue - 1]

        let isMinor = [Quality.minor, .minor7, .halfDiminished7].contains(quality)
        let isDiminished = [Quality.diminished, .diminished7, .halfDiminished7].contains(quality)

        if isMinor && !isDiminished {
            numeral = numeral.lowercased()
        } else if isDiminished {
            numeral = numeral.lowercased()
        }

        let accidentalStr: String
        switch accidental {
        case .natural:
            accidentalStr = ""
        case .flat:
            accidentalStr = "♭"
        case .sharp:
            accidentalStr = "♯"
        }

        let qualitySuffix: String
        switch quality {
        case .major:
            qualitySuffix = ""
        case .minor:
            qualitySuffix = ""
        case .diminished:
            qualitySuffix = "°"
        case .augmented:
            qualitySuffix = "+"
        case .dominant7:
            qualitySuffix = "7"
        case .major7:
            qualitySuffix = "Δ7"
        case .minor7:
            qualitySuffix = "7"
        case .halfDiminished7:
            qualitySuffix = "ø7"
        case .diminished7:
            qualitySuffix = "°7"
        }

        return accidentalStr + numeral + qualitySuffix
    }

    /// Derives a RomanNumeral from a chord in a given key, returning nil if the chord is non-diatonic
    /// and cannot be spelled as a borrowed or chromatic degree.
    /// Handles: Neapolitan (♭II), borrowed major-key chords (♭III, ♭VI, ♭VII), and ♯IV (Lydian/applied-V-of-V).
    public init?(chord: Chord, in key: MusicalKey) {
        let semitones = ((chord.root.rawValue - key.root.rawValue) + 12) % 12
        let keyScaleIntervals = key.scaleIntervals
        let keyDiatonicQualities = key.diatonicQualities

        if let degreeIndex = keyScaleIntervals.firstIndex(of: semitones) {
            let diatonic = Degree(rawValue: degreeIndex + 1)!
            let diatonicQuality = keyDiatonicQualities[degreeIndex]
            let romanQuality = Self.romanQuality(from: chord.quality, diatonic: diatonicQuality)
            self.init(degree: diatonic, accidental: .natural, quality: romanQuality)
            return
        }

        switch key.mode {
        case .major:
            switch semitones {
            case 1:
                if chord.quality == .major {
                    self.init(degree: .two, accidental: .flat, quality: .major)
                    return
                }
            case 3:
                if chord.quality == .major {
                    self.init(degree: .three, accidental: .flat, quality: .major)
                    return
                }
            case 8:
                if chord.quality == .major {
                    self.init(degree: .six, accidental: .flat, quality: .major)
                    return
                }
            case 10:
                if chord.quality == .major {
                    self.init(degree: .seven, accidental: .flat, quality: .major)
                    return
                }
            case 6:
                if chord.quality == .major {
                    self.init(degree: .four, accidental: .sharp, quality: .major)
                    return
                }
            default:
                break
            }

        case .minor:
            break
        }

        return nil
    }

    private static func romanQuality(from chordQuality: ChordQuality, diatonic: ChordQuality) -> Quality {
        switch chordQuality {
        case .major:
            return .major
        case .minor:
            return .minor
        case .diminished:
            return .diminished
        case .augmented:
            return .augmented
        case .dominant7:
            return .dominant7
        case .major7:
            return .major7
        case .minor7:
            return .minor7
        case .halfDiminished7:
            return .halfDiminished7
        case .diminished7:
            return .diminished7
        default:
            return .major
        }
    }
}
