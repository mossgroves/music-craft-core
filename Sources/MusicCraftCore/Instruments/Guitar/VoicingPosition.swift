import Foundation

/// A chord voicing position on the fretboard.
public struct VoicingPosition: Equatable, Hashable, Sendable {
    /// Fret numbers for each string (low E to high E), -1 = muted, 0 = open
    public let frets: [Int]

    /// Finger numbers for each string (0 = open/not fingered, 1–4 = fingers)
    public let fingers: [Int]

    /// Base fret (1 for open position, higher for barre positions)
    public let baseFret: Int

    /// Fret numbers where a barre is placed
    public let barres: [Int]?

    /// Whether this voicing requires a capo
    public let requiresCapo: Bool

    public init(frets: [Int], fingers: [Int], baseFret: Int, barres: [Int]? = nil, requiresCapo: Bool = false) {
        self.frets = frets
        self.fingers = fingers
        self.baseFret = baseFret
        self.barres = barres
        self.requiresCapo = requiresCapo
    }
}

// MARK: - Codable with legacy capo field support

extension VoicingPosition: Codable {
    enum CodingKeys: String, CodingKey {
        case frets
        case fingers
        case baseFret
        case barres
        case requiresCapo
        case capo  // Legacy field
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        frets = try container.decode([Int].self, forKey: .frets)
        fingers = try container.decode([Int].self, forKey: .fingers)
        baseFret = try container.decode(Int.self, forKey: .baseFret)
        barres = try container.decodeIfPresent([Int].self, forKey: .barres)

        // Try new field first, fall back to legacy capo field
        if let requiresCapo = try container.decodeIfPresent(Bool.self, forKey: .requiresCapo) {
            self.requiresCapo = requiresCapo
        } else if let capo = try container.decodeIfPresent(Bool.self, forKey: .capo) {
            self.requiresCapo = capo
        } else {
            self.requiresCapo = false
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(frets, forKey: .frets)
        try container.encode(fingers, forKey: .fingers)
        try container.encode(baseFret, forKey: .baseFret)
        try container.encodeIfPresent(barres, forKey: .barres)
        try container.encode(requiresCapo, forKey: .requiresCapo)
    }
}
