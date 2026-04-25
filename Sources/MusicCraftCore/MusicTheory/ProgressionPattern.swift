import Foundation

/// A well-known chord progression pattern with examples.
public struct ProgressionPattern: Equatable, Hashable, Sendable {
    /// Pattern name (e.g., "Pop Anthem", "Jazz Standard").
    public let name: String
    /// Roman numerals representing the progression.
    public let numerals: [RomanNumeral]
    /// Description of the pattern's characteristics.
    public let description: String
    /// Song examples that exemplify this pattern.
    public let songExamples: [SongReference]

    /// Initializes a ProgressionPattern.
    public init(name: String, numerals: [RomanNumeral], description: String, songExamples: [SongReference]) {
        self.name = name
        self.numerals = numerals
        self.description = description
        self.songExamples = songExamples
    }
}
