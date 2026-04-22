import Foundation

/// One chord in the diatonic series for a key.
public struct DiatonicChordEntry {
    /// Scale degree (1–7).
    public let degree: Int
    /// Roman numeral notation (e.g., "I", "ii", "iii°").
    public let romanNumeral: String
    /// Root note spelled in the key's context.
    public let root: SpelledNote
    /// Chord quality for this degree.
    public let quality: ChordQuality
    /// Display name (e.g., "B♭", "Fm", "C♯°").
    public let chordName: String
    /// Triad notes (three-note chord) built by stacking thirds.
    public let notes: [SpelledNote]

    /// Display string for the triad (e.g., "C-E-G").
    public var notesDisplay: String {
        notes.map(\.displayString).joined(separator: "-")
    }

    /// Whether this entry matches a detected chord (by pitch class and quality).
    public func matchesDetected(root: NoteName, quality: ChordQuality) -> Bool {
        self.root.noteName == root && self.quality == quality
    }
}

/// Related keys: relative major/minor, parallel, dominant, and subdominant.
public struct RelatedKeys {
    /// Relative major (if this is minor) or relative minor (if this is major).
    public let relativeMajorMinor: MusicalKey
    /// Parallel key: same root, opposite mode.
    public let parallelKey: MusicalKey
    /// Dominant key (V of the current key).
    public let dominantKey: MusicalKey
    /// Subdominant key (IV of the current key).
    public let subdominantKey: MusicalKey
}

/// Generates diatonic chords and key information for a given musical key.
public enum DiatonicChordGenerator {

    /// Generate the seven diatonic chords for a key with proper enharmonic spelling.
    public static func generate(for key: MusicalKey) -> [DiatonicChordEntry] {
        let rootLetter = letterName(for: key.root, in: key)
        let intervals = key.scaleIntervals
        let qualities = key.diatonicQualities

        // Build all 7 scale notes as SpelledNotes first
        let scaleNotes: [SpelledNote] = (0..<7).map { degree in
            let letter = rootLetter.advanced(by: degree)
            let targetPitch = (key.root.rawValue + intervals[degree]) % 12
            let acc = accidental(forPitch: targetPitch, letter: letter)
            return SpelledNote(letter: letter, accidental: acc)
        }

        return (0..<7).map { degree in
            let spelledRoot = scaleNotes[degree]
            let quality = qualities[degree]
            let chordName = spelledRoot.displayString + quality.shortSuffix
            let numeral = romanNumeral(degree: degree, quality: quality)

            // Triad notes: root, 3rd, 5th
            let triadNotes = [
                scaleNotes[degree],
                scaleNotes[(degree + 2) % 7],
                scaleNotes[(degree + 4) % 7]
            ]

            return DiatonicChordEntry(
                degree: degree + 1,
                romanNumeral: numeral,
                root: spelledRoot,
                quality: quality,
                chordName: chordName,
                notes: triadNotes
            )
        }
    }

    /// Spell the root note of a key for display (e.g., "B♭" not "A♯").
    public static func spelledRoot(for key: MusicalKey) -> SpelledNote {
        let letter = letterName(for: key.root, in: key)
        let acc = accidental(for: key.root, letter: letter)
        return SpelledNote(letter: letter, accidental: acc)
    }

    /// Display name for a key using proper enharmonic spelling.
    public static func keyDisplayName(for key: MusicalKey) -> String {
        let root = spelledRoot(for: key)
        switch key.mode {
        case .major: return "\(root.displayString) major"
        case .minor: return "\(root.displayString) minor"
        }
    }

    /// Key signature description (e.g., "1♯", "3♭", "no ♯ or ♭").
    public static func keySignature(for key: MusicalKey) -> String {
        let majorSharps: [Int: Int] = [
            0: 0,   // C
            7: 1,   // G
            2: 2,   // D
            9: 3,   // A
            4: 4,   // E
            11: 5,  // B
            6: 6,   // F#
            1: -5,  // Db (C#)
            8: -4,  // Ab
            3: -3,  // Eb
            10: -2, // Bb
            5: -1,  // F
        ]

        let majorRoot: Int
        if key.mode == .minor {
            majorRoot = (key.root.rawValue + 3) % 12
        } else {
            majorRoot = key.root.rawValue
        }

        guard let count = majorSharps[majorRoot] else { return "" }

        if count == 0 {
            return "no ♯ or ♭"
        } else if count > 0 {
            return "\(count)♯"
        } else {
            return "\(abs(count))♭"
        }
    }

    /// Related keys for a given key.
    public static func relatedKeys(for key: MusicalKey) -> RelatedKeys {
        let relativeOffset = key.mode == .major ? 9 : 3
        let relativeRoot = NoteName(rawValue: (key.root.rawValue + relativeOffset) % 12)!
        let relativeMode: KeyMode = key.mode == .major ? .minor : .major

        let dominantRoot = NoteName(rawValue: (key.root.rawValue + 7) % 12)!
        let subdominantRoot = NoteName(rawValue: (key.root.rawValue + 5) % 12)!

        return RelatedKeys(
            relativeMajorMinor: MusicalKey(root: relativeRoot, mode: relativeMode),
            parallelKey: MusicalKey(root: key.root, mode: key.mode == .major ? .minor : .major),
            dominantKey: MusicalKey(root: dominantRoot, mode: key.mode),
            subdominantKey: MusicalKey(root: subdominantRoot, mode: key.mode)
        )
    }

    // MARK: - Spelling Algorithm

    private static func letterName(for note: NoteName, in key: MusicalKey) -> LetterName {
        let usesFlats = keyUsesFlats(root: note, mode: key.mode)

        switch note {
        case .C:  return .C
        case .Cs: return usesFlats ? .D : .C
        case .D:  return .D
        case .Ds: return usesFlats ? .E : .D
        case .E:  return .E
        case .F:  return .F
        case .Fs: return usesFlats ? .G : .F
        case .G:  return .G
        case .Gs: return usesFlats ? .A : .G
        case .A:  return .A
        case .As: return usesFlats ? .B : .A
        case .B:  return .B
        }
    }

    private static func accidental(forPitch pitch: Int, letter: LetterName) -> Accidental {
        let diff = (pitch - letter.naturalPitch + 12) % 12
        switch diff {
        case 0:  return .natural
        case 1:  return .sharp
        case 2:  return .doubleSharp
        case 10: return .doubleFlat
        case 11: return .flat
        default: return .natural
        }
    }

    private static func accidental(for note: NoteName, letter: LetterName) -> Accidental {
        accidental(forPitch: note.rawValue, letter: letter)
    }

    private static func keyUsesFlats(root: NoteName, mode: KeyMode) -> Bool {
        switch mode {
        case .major:
            switch root {
            case .F, .As, .Ds, .Gs, .Cs: return true
            default: return false
            }
        case .minor:
            switch root {
            case .D, .G, .C, .F, .As, .Ds, .Gs: return true
            default: return false
            }
        }
    }

    private static func romanNumeral(degree: Int, quality: ChordQuality) -> String {
        let numerals = ["I", "II", "III", "IV", "V", "VI", "VII"]
        let numeral = numerals[degree]

        switch quality {
        case .minor:
            return numeral.lowercased()
        case .diminished:
            return numeral.lowercased() + "°"
        case .augmented:
            return numeral + "+"
        default:
            return numeral
        }
    }
}
