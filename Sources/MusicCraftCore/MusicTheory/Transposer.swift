import Foundation

/// Transposes Roman numeral notation to concrete chord names for any key.
/// Fixed spelling: sharps for C♯, F♯, G♯, A♯; flats for D♭, E♭, A♭, B♭.
public enum Transposer {

    /// Maps Roman numeral to (semitone offset, quality suffix).
    public static let numeralMap: [String: (offset: Int, quality: String)] = [
        "I": (0, ""),       "i": (0, "m"),
        "ii": (2, "m"),     "II": (2, ""),
        "♭II": (1, ""),
        "iii": (4, "m"),    "III": (4, ""),
        "♭III": (3, ""),
        "IV": (5, ""),      "iv": (5, "m"),
        "V": (7, ""),       "v": (7, "m"),
        "vi": (9, "m"),     "VI": (9, ""),
        "♭VI": (8, ""),
        "vii°": (11, "dim"), "VII": (11, ""),
        "♭VII": (10, ""),
        "ii°": (2, "dim"),
    ]

    /// Note names indexed by semitone (0–11), using fixed sharp/flat spelling.
    public static let noteNames = ["C", "C♯", "D", "E♭", "E", "F", "F♯", "G", "A♭", "A", "B♭", "B"]

    /// Convert a Roman numeral to a concrete chord name in the given key.
    /// - Parameters:
    ///   - numeral: Roman numeral (e.g., "I", "vi", "♭VII", "vii°").
    ///   - rootSemitone: Root pitch class (0–11): C=0, C♯=1, D=2, etc.
    /// - Returns: Chord name (e.g., "G", "Em", "Bdim") or the input numeral if unknown.
    public static func chordName(_ numeral: String, rootSemitone: Int) -> String {
        guard let entry = numeralMap[numeral] else { return numeral }
        let note = noteNames[(rootSemitone + entry.offset) % 12]
        return note + entry.quality
    }

    /// Transpose an entire progression of Roman numerals to a key.
    public static func transposeProgression(_ numerals: [String], rootSemitone: Int) -> [String] {
        numerals.map { chordName($0, rootSemitone: rootSemitone) }
    }

    /// Format a progression as a display string with en-dash separators.
    public static func displayString(for numerals: [String], rootSemitone: Int) -> String {
        transposeProgression(numerals, rootSemitone: rootSemitone).joined(separator: "–")
    }
}
