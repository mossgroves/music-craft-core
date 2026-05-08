import Foundation

/// Capo position suggestions for transposing voicing-rich keys to target keys.
public enum CapoCalculator {
    /// Returns top capo position suggestions for a target key.
    ///
    /// The algorithm:
    /// 1. Generate a source-key pool based on mode (major → [C, G, D, A, E]; minor → [A, E, D])
    /// 2. For each source key, compute capo fret = (target root - source root) mod 12
    /// 3. Score by diatonic chord richness (sum of voicing counts in VoicingLibrary for that key)
    /// 4. Return top 3 by score descending, ties broken by lower capoFret
    ///
    /// Mode is preserved: major target → major sources, minor target → minor sources.
    /// Relative major↔minor mapping is deferred to future versions.
    ///
    /// - Parameters:
    ///   - targetKey: Target key for the singer
    ///   - tuning: Guitar tuning (default: .standard)
    ///   - maxCapoFret: Maximum capo fret to suggest (default: 7)
    /// - Returns: Up to 3 CapoSuggestion items sorted by score (diatonic richness) descending
    public static func suggestions(
        targetKey: MusicalKey,
        tuning: GuitarTuning = .standard,
        maxCapoFret: Int = 7
    ) -> [CapoSuggestion] {
        // Generate source-key pool based on target mode
        let sourceKeys: [MusicalKey] = sourceKeyPool(for: targetKey)

        var candidates: [CapoSuggestion] = []

        for sourceKey in sourceKeys {
            // Compute capo fret
            let semitoneDistance = (targetKey.root.rawValue - sourceKey.root.rawValue + 12) % 12
            let capoFret = semitoneDistance

            guard capoFret <= maxCapoFret else {
                continue
            }

            // Score by diatonic chord richness: count voicings for all 7 diatonic chords in source key
            var richness: Double = 0
            let diatonicChords = DiatonicChordGenerator.generate(for: sourceKey)
            for entry in diatonicChords {
                let chord = Chord(root: entry.root.noteName, quality: entry.quality)
                let voicings = VoicingLibrary.voicings(for: chord, tuning: tuning, limit: 10)
                richness += Double(voicings.count)
            }

            let suggestion = CapoSuggestion(
                sourceKey: sourceKey,
                capoFret: capoFret,
                targetKey: targetKey,
                score: richness
            )
            candidates.append(suggestion)
        }

        // Sort: by score descending, then by capoFret ascending
        candidates.sort { a, b in
            if a.score != b.score {
                return a.score > b.score
            }
            return a.capoFret < b.capoFret
        }

        // Return top 3
        return Array(candidates.prefix(3))
    }

    /// Generate source-key pool for a target key, preserving mode.
    private static func sourceKeyPool(for targetKey: MusicalKey) -> [MusicalKey] {
        switch targetKey.mode {
        case .major:
            // Major pool: common major keys with good voicing coverage
            return [
                MusicalKey(root: .C, mode: .major),
                MusicalKey(root: .G, mode: .major),
                MusicalKey(root: .D, mode: .major),
                MusicalKey(root: .A, mode: .major),
                MusicalKey(root: .E, mode: .major),
            ]
        case .minor:
            // Minor pool
            return [
                MusicalKey(root: .A, mode: .minor),
                MusicalKey(root: .E, mode: .minor),
                MusicalKey(root: .D, mode: .minor),
            ]
        }
    }
}

/// A capo position suggestion for transposing to a target key.
public struct CapoSuggestion: Equatable, Hashable, Sendable {
    /// Source key (has rich voicings in the library)
    public let sourceKey: MusicalKey

    /// Capo fret number (0 = no capo, 1–12 = fret)
    public let capoFret: Int

    /// Resulting target key for the listener
    public let targetKey: MusicalKey

    /// Score: sum of voicing counts for diatonic chords in sourceKey
    /// Higher scores indicate more voicing options
    public let score: Double

    public init(sourceKey: MusicalKey, capoFret: Int, targetKey: MusicalKey, score: Double) {
        self.sourceKey = sourceKey
        self.capoFret = capoFret
        self.targetKey = targetKey
        self.score = score
    }
}
