import Foundation

/// A chord with root, quality, and associated metadata.
public struct Chord: Equatable, Identifiable {
    /// Unique identifier.
    public let id: UUID
    /// Root note of the chord.
    public let root: NoteName
    /// Quality (major, minor, seventh, etc.).
    public let quality: ChordQuality
    /// Confidence score (0–1), used by detection systems.
    public let confidence: Double
    /// Pitch classes present in the chord.
    public let notes: [NoteName]
    /// Timestamp when the chord was detected or created.
    public let timestamp: Date

    /// Initializes a chord with explicit values.
    public init(id: UUID = UUID(), root: NoteName, quality: ChordQuality, confidence: Double = 1.0, notes: [NoteName] = [], timestamp: Date = Date()) {
        self.id = id
        self.root = root
        self.quality = quality
        self.confidence = confidence
        self.notes = notes
        self.timestamp = timestamp
    }

    /// Parses a chord name string (e.g., "Am7", "F♯", "B♭dim") and returns a Chord, or nil if unparseable.
    /// Handles Unicode notation (♯, ♭, °, +, ø7) and ASCII equivalents (#, b, dim, aug, m7b5).
    /// Quality defaults to major if not recognized.
    public init?(parsing name: String) {
        let parsed = Self.parseChordName(name)
        guard let root = Self.noteNameFromString(parsed.root) else { return nil }
        let quality = Self.chordQualityFromString(parsed.quality)
        self.init(root: root, quality: quality, confidence: 1.0, notes: [], timestamp: Date())
    }

    /// Display name (e.g., "Am7").
    public var displayName: String {
        return "\(root.displayName)\(quality.shortSuffix)"
    }

    /// Full display name (e.g., "A minor seventh").
    public var fullDisplayName: String {
        return "\(root.displayName) \(quality.displayName)"
    }

    public static func == (lhs: Chord, rhs: Chord) -> Bool {
        return lhs.root == rhs.root && lhs.quality == rhs.quality
    }

    // MARK: - Parsing Helpers

    /// Parse a chord name into (root, quality) components.
    /// Normalizes Unicode (♯→#, ♭→b, °→dim, +→aug, ø7→m7b5) and extracts root and suffix.
    private static func parseChordName(_ name: String) -> (root: String, quality: String) {
        var s = name
        s = s.replacingOccurrences(of: "♯", with: "#")
        s = s.replacingOccurrences(of: "♭", with: "b")

        // Handle suffix substitutions before root extraction
        s = s.replacingOccurrences(of: "ø7", with: "_m7b5_")
        s = s.replacingOccurrences(of: "°7", with: "_dim7_")
        s = s.replacingOccurrences(of: "°", with: "_dim_")
        s = s.replacingOccurrences(of: "+", with: "_aug_")

        // Extract root: 1-2 chars (letter + optional # or b)
        var root = ""
        var rest = s
        if let first = rest.first, first.isLetter && first.isUppercase {
            root = String(first)
            rest = String(rest.dropFirst())
            if let second = rest.first, second == "#" || second == "b" {
                root += String(second)
                rest = String(rest.dropFirst())
            }
        }

        // Restore quality from marker substitutions
        var quality = rest
        quality = quality.replacingOccurrences(of: "_m7b5_", with: "m7b5")
        quality = quality.replacingOccurrences(of: "_dim7_", with: "dim7")
        quality = quality.replacingOccurrences(of: "_dim_", with: "dim")
        quality = quality.replacingOccurrences(of: "_aug_", with: "aug")

        return (root, quality)
    }

    /// Convert a note name string (e.g., "C", "F#", "Bb") to a NoteName enum.
    private static func noteNameFromString(_ s: String) -> NoteName? {
        switch s {
        case "C": return .C
        case "C#", "Db": return .Cs
        case "D": return .D
        case "D#", "Eb": return .Ds
        case "E": return .E
        case "F": return .F
        case "F#", "Gb": return .Fs
        case "G": return .G
        case "G#", "Ab": return .Gs
        case "A": return .A
        case "A#", "Bb": return .As
        case "B": return .B
        default: return nil
        }
    }

    /// Convert a quality suffix string (e.g., "m", "7", "maj7") to a ChordQuality enum.
    /// Defaults to major if not recognized.
    private static func chordQualityFromString(_ s: String) -> ChordQuality {
        switch s {
        case "": return .major
        case "m": return .minor
        case "7": return .dominant7
        case "maj7": return .major7
        case "m7": return .minor7
        case "m(maj7)": return .minorMajor7
        case "dim": return .diminished
        case "dim7": return .diminished7
        case "aug": return .augmented
        case "sus2": return .sus2
        case "sus4": return .sus4
        case "add9": return .add9
        case "m9": return .minor9
        case "maj9": return .major9
        case "m7b5": return .halfDiminished7
        case "5": return .power
        default: return .major
        }
    }
}
