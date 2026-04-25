import Foundation

/// A progression pattern recognized in a chord sequence.
public struct RecognizedPattern: Equatable, Hashable, Sendable {
    /// Match type indicating whether the match was exact or fuzzy.
    public enum MatchType: Equatable, Hashable, Sendable {
        case exact
        case similar
    }

    /// The matched pattern.
    public let pattern: ProgressionPattern
    /// Match type: exact or similar.
    public let matchType: MatchType

    /// Initializes a RecognizedPattern.
    public init(pattern: ProgressionPattern, matchType: MatchType) {
        self.pattern = pattern
        self.matchType = matchType
    }

    /// Pattern name (pass-through).
    public var name: String {
        pattern.name
    }

    /// Pattern description (pass-through).
    public var description: String {
        pattern.description
    }

    /// Song examples (pass-through).
    public var songExamples: [SongReference] {
        pattern.songExamples
    }

    /// Display string: Roman numerals joined with "–".
    public var displayString: String {
        pattern.numerals.map(\.displayString).joined(separator: "–")
    }
}
