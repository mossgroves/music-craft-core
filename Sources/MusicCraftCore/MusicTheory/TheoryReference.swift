import Foundation

// MARK: - Scale Data

/// Scale definition with intervals and degree information.
public struct ScaleData: Codable {
    public var intervals: [Int]?
    public var intervalsAscending: [Int]?
    public var intervalsDescending: [Int]?
    public var degreeNames: [String]?
    public var degreeNumerals: [String]?
    public var degreeQualities: [String]?
    public var modes: [String: ModeData]?
    public var character: String?
    public var note: String?
}

/// Mode within a scale (e.g., dorian within major).
public struct ModeData: Codable {
    public let startDegree: Int?
    public let character: String?
}

// MARK: - Interval Data

/// Musical interval definition.
public struct IntervalData: Codable {
    public let semitones: Int
    public let abbreviation: String
    public var character: String?
}

// MARK: - Chord Formula Data

/// Chord formula with intervals and emotional character.
public struct ChordFormulaData: Codable {
    public let intervals: [Int]
    public let symbol: String
    public var character: String?
}

// MARK: - Circle of Fifths Data

/// Circle of fifths reference data.
public struct CircleOfFifthsData: Codable {
    public let order: [String]
    public let sharpsByKey: [String: Int]
    public let flatsByKey: [String: Int]
    public let relativeMinors: [String: String]
}

// MARK: - Progression Data

/// A named chord progression with example and character.
public struct ProgressionData: Codable {
    public let numerals: String
    public let name: String
    public var exampleKeyD: String?
    public var character: String?
}

// MARK: - Key Detection Rules Data

/// Key detection heuristic rules.
public struct KeyDetectionRulesData: Codable {
    public let description: String
    public let rules: [String]
}

// MARK: - Music Theory Reference Data

/// Top-level container for all music theory reference data loaded from music_theory.json.
public struct MusicTheoryData: Codable {
    public let scales: [String: ScaleData]
    public let intervals: [String: IntervalData]
    public let chordFormulas: [String: ChordFormulaData]
    public let circleOfFifths: CircleOfFifthsData
    public let commonProgressions: [String: [ProgressionData]]
    public let keyDetectionRules: KeyDetectionRulesData
}

// MARK: - Theory Reference

/// Singleton loader for music_theory.json reference data.
public struct TheoryReference {
    /// All scale definitions (major, minor, pentatonic, blues, etc.).
    public let scales: [String: ScaleData]
    /// All interval definitions.
    public let intervals: [String: IntervalData]
    /// All chord formula definitions.
    public let chordFormulas: [String: ChordFormulaData]
    /// Circle of fifths data.
    public let circleOfFifths: CircleOfFifthsData
    /// Common chord progressions organized by category.
    public let commonProgressions: [String: [ProgressionData]]
    /// Key detection heuristic rules.
    public let keyDetectionRules: KeyDetectionRulesData

    private init(data: MusicTheoryData) {
        self.scales = data.scales
        self.intervals = data.intervals
        self.chordFormulas = data.chordFormulas
        self.circleOfFifths = data.circleOfFifths
        self.commonProgressions = data.commonProgressions
        self.keyDetectionRules = data.keyDetectionRules
    }

    /// Load music_theory.json from the bundle.
    /// - Returns: TheoryReference instance with decoded data, or throws on decode error.
    public static func load() throws -> TheoryReference {
        guard let url = Bundle.module.url(forResource: "music_theory", withExtension: "json") else {
            throw NSError(domain: "TheoryReference", code: 1, userInfo: [NSLocalizedDescriptionKey: "music_theory.json not found in bundle"])
        }

        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let theoryData = try decoder.decode(MusicTheoryData.self, from: data)

        return TheoryReference(data: theoryData)
    }

    /// Lazily-loaded shared instance. Fatally errors if the bundled JSON cannot be decoded (programmer error).
    public static let shared: TheoryReference = {
        do {
            return try load()
        } catch {
            fatalError("Failed to load music_theory.json: \(error)")
        }
    }()
}
