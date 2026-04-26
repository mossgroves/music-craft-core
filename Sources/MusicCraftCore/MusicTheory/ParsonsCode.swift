import Foundation

/// Symbolic melodic direction in Parsons code notation.
///
/// Parsons code is a standard notation in Music Information Retrieval for relative pitch direction:
/// each symbol represents the direction from one note to the next (up, down, or same).
/// This enables melodic similarity matching and indexing independent of absolute pitch.
///
/// Display strings match standard Parsons code notation used in MIR literature.
public enum ParsonsCode: String, Equatable, Hashable, Sendable, CaseIterable {
    /// Up: current note is higher than the previous note. Display: "*"
    case up = "*"
    /// Down: current note is lower than the previous note. Display: "d"
    case down = "d"
    /// Repeat (same): current note has the same pitch as the previous note. Display: "r"
    /// (Named with trailing underscore to avoid Swift keyword conflict.)
    case repeat_ = "r"
}
