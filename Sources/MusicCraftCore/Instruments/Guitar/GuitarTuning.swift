import Foundation

/// A guitar tuning defined by the open-string notes and their reference frequencies.
public enum GuitarTuning: String, CaseIterable, Equatable, Hashable, Sendable, Codable {
    /// Standard tuning: E-A-D-G-B-E (low to high)
    case standard = "Standard"
    case dropD = "Drop D"
    case openD = "Open D"
    case openG = "Open G"
    case dadgad = "DADGAD"
    case cgdgbd = "CGDGBD"

    /// Identifier for the tuning (lowercased, no spaces)
    public var id: String {
        rawValue.lowercased().replacingOccurrences(of: " ", with: "")
    }

    /// Human-readable name
    public var displayName: String { rawValue }

    /// Short name for compact display
    public var shortName: String {
        switch self {
        case .standard: return "Std"
        case .dropD: return "DD"
        case .openD: return "OD"
        case .openG: return "OG"
        case .dadgad: return "DAD"
        case .cgdgbd: return "CGD"
        }
    }

    /// Semitone intervals from C0 (MIDI note 0) for each open string (low to high)
    /// C=0, C#=1, D=2, D#=3, E=4, F=5, F#=6, G=7, G#=8, A=9, A#=10, B=11
    public var semitones: [Int] {
        switch self {
        case .standard: return [40, 45, 50, 55, 59, 64]  // E A D G B E
        case .dropD: return [38, 45, 50, 55, 59, 64]     // D A D G B E
        case .openD: return [38, 45, 50, 54, 57, 62]     // D A D F# A D
        case .openG: return [38, 43, 50, 55, 59, 67]     // D G D G B D
        case .dadgad: return [38, 45, 50, 55, 57, 62]    // D A D G A D
        case .cgdgbd: return [36, 43, 50, 55, 59, 62]    // C G D G B D
        }
    }

    /// Reference frequencies in Hz for each open string (A4 = 440 Hz, 12-tone equal temperament)
    public var referenceFrequencies: [Double] {
        semitones.map { midiNote in
            // f = 440 * 2^((n - 69) / 12), where n is MIDI note number
            440.0 * pow(2.0, Double(midiNote - 69) / 12.0)
        }
    }

    /// Human-readable description of the tuning
    public var description: String {
        switch self {
        case .standard: return "Standard tuning (E A D G B E)"
        case .dropD: return "Drop D tuning (D A D G B E)"
        case .openD: return "Open D tuning (D A D F# A D)"
        case .openG: return "Open G tuning (D G D G B D)"
        case .dadgad: return "DADGAD tuning (D A D G A D)"
        case .cgdgbd: return "CGDGBD tuning (C G D G B D)"
        }
    }
}
