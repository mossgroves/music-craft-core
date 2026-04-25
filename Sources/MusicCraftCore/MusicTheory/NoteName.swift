import Foundation

/// The 12 chromatic notes (C through B, with sharps).
public enum NoteName: Int, CaseIterable, Sendable {
    case C = 0, Cs, D, Ds, E, F, Fs, G, Gs, A, As, B

    /// Display name using sharp symbol (e.g., "C♯").
    public var displayName: String {
        switch self {
        case .C: return "C"
        case .Cs: return "C♯"
        case .D: return "D"
        case .Ds: return "D♯"
        case .E: return "E"
        case .F: return "F"
        case .Fs: return "F♯"
        case .G: return "G"
        case .Gs: return "G♯"
        case .A: return "A"
        case .As: return "A♯"
        case .B: return "B"
        }
    }

    /// Display name using flat symbol (e.g., "D♭").
    public var flatName: String {
        switch self {
        case .C: return "C"
        case .Cs: return "D♭"
        case .D: return "D"
        case .Ds: return "E♭"
        case .E: return "E"
        case .F: return "F"
        case .Fs: return "G♭"
        case .G: return "G"
        case .Gs: return "A♭"
        case .A: return "A"
        case .As: return "B♭"
        case .B: return "B"
        }
    }
}
