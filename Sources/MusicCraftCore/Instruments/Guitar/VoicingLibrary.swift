import Foundation

/// A library of guitar voicings indexed by chord name and tuning.
public enum VoicingLibrary {
    /// Returns ranked playable voicings for a chord on a tuning.
    ///
    /// Non-standard tunings return empty array in v0.0.10 (per-tuning data landing in 0.0.11).
    /// Voicings are ranked by the order they appear in the bundled JSON (best first).
    ///
    /// - Parameters:
    ///   - chord: Target chord
    ///   - tuning: Guitar tuning (default: .standard)
    ///   - limit: Maximum number of voicings to return (default: 5)
    /// - Returns: Array of GuitarVoicing sorted by rank (best first), or empty if chord/tuning not found
    public static func voicings(
        for chord: Chord,
        tuning: GuitarTuning = .standard,
        limit: Int = 5
    ) -> [GuitarVoicing] {
        // v0.0.10: Only standard tuning has data
        guard tuning == .standard else {
            return []
        }

        // Load bundled voicings and find matches
        guard let positions = loadBundledVoicings()[chordToJSONKey(chord)] else {
            return []
        }

        // Convert positions to GuitarVoicing objects, limited by the limit parameter
        return positions.prefix(limit).map { position in
            GuitarVoicing(chord: chord, tuning: tuning, position: position)
        }
    }

    /// Convert a Chord to the JSON key string used in guitar_voicings.json.
    /// Maps Chord (root + quality enum) to ASCII chord name string.
    private static func chordToJSONKey(_ chord: Chord) -> String {
        let rootDisplay = chord.root.displayName.replacingOccurrences(of: "♯", with: "#").replacingOccurrences(of: "♭", with: "b")
        return rootDisplay + chord.quality.shortSuffix
    }

    /// Load and cache the bundled voicings JSON.
    private static let cachedVoicings: [String: [VoicingPosition]] = {
        loadBundledVoicings()
    }()

    private static func loadBundledVoicings() -> [String: [VoicingPosition]] {
        guard let url = Bundle.module.url(forResource: "guitar_voicings", withExtension: "json") else {
            return [:]
        }

        do {
            let data = try Data(contentsOf: url)
            let decoded = try JSONDecoder().decode(VoicingsContainer.self, from: data)
            return decoded.voicings
        } catch {
            print("Failed to load bundled guitar voicings: \(error)")
            return [:]
        }
    }
}

// MARK: - Codable Container

private struct VoicingsContainer: Codable {
    let voicings: [String: [VoicingPosition]]
}
