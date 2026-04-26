import Foundation

/// Key inference from detected monophonic notes.
///
/// Distinct from `ProgressionAnalyzer.inferKey`, which infers key from chord progressions.
/// MelodyKeyInference works on raw note sequences and is suitable for pitch contours,
/// hummed fragments, and melodic analysis where chord-level information is unavailable.
///
/// Algorithm: Accumulate pitch classes from detected notes → score all 24 keys by diatonic fit →
/// disambiguate ties using tonic frequency → return ranked candidates.
public enum MelodyKeyInference {

    /// Infer the top key candidates from detected notes.
    ///
    /// - Parameters:
    ///   - notes: Array of detected note events (minimum 3 notes, minimum 2 distinct pitch classes).
    ///   - maxCandidates: Maximum number of candidates to return (default 2).
    /// - Returns: Key candidates ranked by diatonic fit score. Empty array if insufficient input.
    public static func infer(
        from notes: [DetectedNote],
        maxCandidates: Int = 2
    ) -> [KeyCandidate] {
        guard notes.count >= 3 else { return [] }

        // Build frequency count of pitch classes
        var pitchClassCounts: [Int: Int] = [:]
        for note in notes {
            pitchClassCounts[note.pitchClass, default: 0] += 1
        }

        let distinctPitchClasses = Set(pitchClassCounts.keys)
        guard distinctPitchClasses.count >= 2 else { return [] }

        // Score all 24 keys
        var candidates: [(candidate: KeyCandidate, score: Double)] = []

        let majorTemplate: Set<Int> = [0, 2, 4, 5, 7, 9, 11]
        let minorTemplate: Set<Int> = [0, 2, 3, 5, 7, 8, 10]

        for root in 0..<12 {
            for (mode, template) in [(KeyMode.major, majorTemplate), (KeyMode.minor, minorTemplate)] {
                // Compute diatonic pitch classes for this key
                let diatonicPitches = Set(template.map { ($0 + root) % 12 })

                // Score: fraction of detected pitch classes that are diatonic
                let diatonicCount = distinctPitchClasses.filter { diatonicPitches.contains($0) }.count
                let score = Double(diatonicCount) / Double(distinctPitchClasses.count)

                guard score > 0 else { continue }

                let noteName = NoteName(rawValue: root) ?? .C
                let key = MusicalKey(root: noteName, mode: mode)
                let tonicFrequency = pitchClassCounts[root, default: 0]

                let candidate = KeyCandidate(
                    key: key,
                    score: score,
                    tonicFrequency: tonicFrequency
                )
                candidates.append((candidate, score))
            }
        }

        guard !candidates.isEmpty else { return [] }

        // Sort by score descending
        candidates.sort { $0.score > $1.score }

        // Disambiguate ties by tonic frequency and minor preference
        let maxScore = candidates[0].score
        let topGroup = candidates.filter { $0.score == maxScore }

        let disambiguated = topGroup.sorted { a, b in
            let aTonicFreq = a.candidate.tonicFrequency
            let bTonicFreq = b.candidate.tonicFrequency

            if aTonicFreq != bTonicFreq {
                return aTonicFreq > bTonicFreq
            }

            // If tied on frequency, prefer minor
            if a.candidate.key.mode != b.candidate.key.mode {
                return a.candidate.key.mode == .minor
            }

            return false
        }

        // Return top maxCandidates, deduplicating by key
        var result: [KeyCandidate] = []
        var seen: Set<MusicalKey> = []

        for item in disambiguated {
            if !seen.contains(item.candidate.key) {
                result.append(item.candidate)
                seen.insert(item.candidate.key)
                if result.count >= maxCandidates {
                    break
                }
            }
        }

        // If we need more candidates, take from the next score tier
        if result.count < maxCandidates {
            let remaining = candidates.filter { !seen.contains($0.candidate.key) }
            for item in remaining {
                if !seen.contains(item.candidate.key) {
                    result.append(item.candidate)
                    seen.insert(item.candidate.key)
                    if result.count >= maxCandidates {
                        break
                    }
                }
            }
        }

        return result
    }

    // MARK: - KeyCandidate

    /// A ranked key inference candidate with score and tonic frequency.
    public struct KeyCandidate: Equatable, Hashable, Sendable {
        /// The inferred musical key.
        public let key: MusicalKey

        /// Diatonic fit score (0.0–1.0): fraction of detected pitch classes that are diatonic to this key.
        public let score: Double

        /// Frequency count of the tonic pitch class in the detected notes. Used for tie-breaking.
        public let tonicFrequency: Int

        /// Creates a KeyCandidate with key, score, and tonic frequency.
        public init(key: MusicalKey, score: Double, tonicFrequency: Int) {
            self.key = key
            self.score = score
            self.tonicFrequency = tonicFrequency
        }
    }
}
