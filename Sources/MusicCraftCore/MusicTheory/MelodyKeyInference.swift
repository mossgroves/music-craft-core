import Foundation

/// Key inference from detected monophonic notes.
///
/// Distinct from `ProgressionAnalyzer.inferKey`, which infers key from chord progressions.
/// MelodyKeyInference works on raw note sequences and is suitable for pitch contours,
/// hummed fragments, and melodic analysis where chord-level information is unavailable.
///
/// Algorithm (0.0.12+): build a duration-weighted pitch-class profile from the notes →
/// score all 24 keys by Pearson correlation against the Krumhansl–Kessler tonal hierarchy
/// rotated to each tonic → rank by correlation. Because a major key and its relative minor
/// share a scale but have *different* tonal profiles, this distinguishes them — replacing the
/// prior diatonic-fraction scoring, which tied every relative pair and broke the tie with a
/// hard-wired minor preference (making every inference a minor-biased coin toss).
public enum MelodyKeyInference {

    /// Krumhansl–Kessler key profiles (probe-tone tonal hierarchy).
    /// Source: Krumhansl, C. L. (1990). *Cognitive Foundations of Musical Pitch*, Table 2.1
    /// (derived from Krumhansl & Kessler, 1982). Index 0 = tonic, ascending semitones.
    /// Temperley (2007) and Aarden (2003) variants are drop-in swappable here if the eval
    /// suggests a better fit for sung-melody input.
    static let kkMajor: [Double] = [6.35, 2.23, 3.48, 2.33, 4.38, 4.09, 2.52, 5.19, 2.39, 3.66, 2.29, 2.88]
    static let kkMinor: [Double] = [6.33, 2.68, 3.52, 5.38, 2.60, 3.53, 2.54, 4.75, 3.98, 2.69, 3.34, 3.17]

    /// Infer the top key candidates from detected notes.
    ///
    /// - Parameters:
    ///   - notes: Array of detected note events (minimum 3 notes, minimum 2 distinct pitch classes).
    ///   - maxCandidates: Maximum number of candidates to return (default 2).
    /// - Returns: Key candidates ranked by tonal-profile correlation. Empty array if insufficient input.
    public static func infer(
        from notes: [DetectedNote],
        maxCandidates: Int = 2
    ) -> [KeyCandidate] {
        guard notes.count >= 3 else { return [] }

        // Duration-weighted pitch-class profile. A held note counts more than a passing one;
        // confidence gently modulates (floored at 0.1 so a low-confidence note still registers).
        var weights = [Double](repeating: 0, count: 12)
        var pitchClassNoteCounts = [Int](repeating: 0, count: 12)
        for note in notes {
            let pc = ((note.pitchClass % 12) + 12) % 12
            let conf = min(1.0, max(0.1, note.confidence))
            weights[pc] += max(note.duration, 1e-3) * conf
            pitchClassNoteCounts[pc] += 1
        }

        let distinctPitchClasses = weights.filter { $0 > 0 }.count
        guard distinctPitchClasses >= 2 else { return [] }

        // Score every key by Pearson correlation between the weight profile and the KK profile
        // rotated to that key's tonic. Iterate roots/modes in a fixed order and rank with a
        // total-order comparator (no equal elements) so the result is fully deterministic —
        // no reliance on Set/Dictionary iteration order, and no minor tie-break.
        struct Scored { let key: MusicalKey; let corr: Double; let tonicFreq: Int }
        var scored: [Scored] = []
        scored.reserveCapacity(24)

        for root in 0..<12 {
            for mode in [KeyMode.major, KeyMode.minor] {
                let profile = mode == .major ? kkMajor : kkMinor
                var rotated = [Double](repeating: 0, count: 12)
                for pc in 0..<12 { rotated[pc] = profile[((pc - root) % 12 + 12) % 12] }
                let corr = pearson(weights, rotated)
                let noteName = NoteName(rawValue: root) ?? .C
                scored.append(Scored(key: MusicalKey(root: noteName, mode: mode),
                                     corr: corr,
                                     tonicFreq: pitchClassNoteCounts[root]))
            }
        }

        scored.sort { a, b in
            if a.corr != b.corr { return a.corr > b.corr }            // primary: correlation
            if a.tonicFreq != b.tonicFreq { return a.tonicFreq > b.tonicFreq } // then tonic emphasis
            if a.key.root.rawValue != b.key.root.rawValue { return a.key.root.rawValue < b.key.root.rawValue }
            return a.key.mode == .major && b.key.mode == .minor       // stable, NOT minor-biased
        }

        // Build candidates. score = winning correlation clamped to [0, 1] (a 0–1 confidence).
        // NOTE: this score's scale differs from the pre-0.0.12 diatonic-fraction score.
        // Sanctuary's HarmonyKeyGate threshold (0.6) was calibrated to the old score and will
        // likely need recalibration — see the eval re-run distribution. (No gate changed here.)
        var result: [KeyCandidate] = []
        for s in scored.prefix(max(0, maxCandidates)) {
            result.append(KeyCandidate(key: s.key,
                                       score: min(1.0, max(0.0, s.corr)),
                                       tonicFrequency: s.tonicFreq))
        }
        return result
    }

    /// Pearson correlation coefficient between two equal-length vectors. Returns 0 when either
    /// vector has zero variance (no meaningful correlation).
    static func pearson(_ a: [Double], _ b: [Double]) -> Double {
        let n = Double(a.count)
        guard n > 0 else { return 0 }
        let ma = a.reduce(0, +) / n
        let mb = b.reduce(0, +) / n
        var num = 0.0, da = 0.0, db = 0.0
        for i in 0..<a.count {
            let xa = a[i] - ma, xb = b[i] - mb
            num += xa * xb; da += xa * xa; db += xb * xb
        }
        let den = (da * db).squareRoot()
        return den > 0 ? num / den : 0
    }

    // MARK: - KeyCandidate

    /// A ranked key inference candidate with score and tonic frequency.
    public struct KeyCandidate: Equatable, Hashable, Sendable {
        /// The inferred musical key.
        public let key: MusicalKey

        /// Confidence in `[0, 1]`, derived from the winning Krumhansl–Kessler profile
        /// correlation (clamped). As of 0.0.12 this is a tonal-profile correlation, NOT the
        /// pre-0.0.12 diatonic-fraction. Consumers that gated on the old score (e.g. Sanctuary's
        /// `HarmonyKeyGate` at 0.6) should recalibrate against the new distribution.
        public let score: Double

        /// Note count of the tonic pitch class in the detected notes. Retained as a stable
        /// secondary tie-breaker and for consumer display.
        public let tonicFrequency: Int

        /// Creates a KeyCandidate with key, score, and tonic frequency.
        public init(key: MusicalKey, score: Double, tonicFrequency: Int) {
            self.key = key
            self.score = score
            self.tonicFrequency = tonicFrequency
        }
    }
}
