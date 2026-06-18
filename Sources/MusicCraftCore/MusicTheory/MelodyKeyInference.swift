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

    // MARK: - Structural re-rank tuning (2026-06-18; docs/specs/tonic-key-detection-redesign.md, Phase 1)
    //
    // The Krumhansl–Kessler correlation above is order-blind: it counts a note's weight but not WHEN
    // it sounds, so a D-then-G drone (home = D) read as G major — the histogram can't tell I from IV.
    // The cues a listener uses to hear "home" — the note you OPEN on, and (corroborating) the note you
    // END on — live in `DetectedNote.onsetTime`/`duration`, which the histogram discards. We restore
    // them as a *re-rank*, deliberately bounded so they can only break a genuine near-tie, never
    // overturn a clear histogram winner. All values are starting points, tuned against the 16
    // existing tests as fixed anchors and frozen on real Taylor 812ce-n recordings (Step 4).
    /// Top-N histogram candidates eligible for the re-rank.
    static let shortlistN = 6
    /// Near-tie window (normalised correlation): two candidates this close are "tied" for the abstain
    /// check. A clear histogram winner leaves no near-tie → it's never disturbed (existing-test floor).
    static let contendMargin = 0.05
    /// How far behind the histogram leader the OPENING note's own key may sit and still overturn it —
    /// but only on a classic ambiguity (relative / fifth / fourth). Larger than `contendMargin`
    /// because the KK profile systematically scores the dominant above the subdominant, so the
    /// rightful tonic of a I-IV drone (D under a D→G vamp) trails the IV (G) by more than a hair —
    /// yet still bounded so a *decisive* winner (a clearly-stated key that merely opens on its V) is
    /// never flipped. The single most load-bearing constant; frozen on real Taylor takes (Step 4).
    static let openingOverturnMargin = 0.15
    /// On a low-confidence near-tie (a classic ambiguity with conflicting/weak structural evidence),
    /// the winner's score is capped here so it sits below a consumer's tonal-clarity gate — the key
    /// surfaces fall quiet ("you pick") rather than commit a confident coin-flip. Kept below the
    /// HarmonyKeyGate floor Sanctuary uses; the raw-correlation scale is otherwise unchanged.
    static let nearTieScoreCeiling = 0.45

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

        // ---- Structural re-rank (2026-06-18) — break a near-tie with the note timing the histogram
        // throws away. A clear histogram winner (nobody within `contendMargin`) is left untouched,
        // so every decisive correlation call — and the existing-test floor — is preserved.
        let opening = Self.boundaryPitchClass(notes, atStart: true)
        let closing = Self.boundaryPitchClass(notes, atStart: false)
        func corrNorm(_ c: Double) -> Double { (c + 1) / 2 }   // [-1,1] → [0,1] for a fair gap

        func favored(by pc: Int?, _ a: Scored, _ b: Scored) -> Scored? {
            guard let pc else { return nil }
            if a.key.root.rawValue == pc { return a }
            if b.key.root.rawValue == pc { return b }
            return nil
        }

        let leader = scored[0]
        var winner = leader
        var lowConfidence = false

        // The OPENING note is a strong "home" cue the histogram ignores. It matters most for exactly
        // the pair the KK profile CAN'T separate: the perfect-fifth/fourth (I vs V / I vs IV) and the
        // relative (I vs vi). The profile always scores the dominant above the subdominant, so a
        // D-then-G drone (home = D) leads to G major (tonic+fifth fits better than tonic+fourth) —
        // the headline bug. When the histogram leader and the opening note's own best key form one of
        // these classic ambiguities AND the opening key trails by no more than `openingOverturnMargin`
        // (bounded so a *decisive* winner can never be flipped — the existing-test floor), trust the
        // opening: it's home. The closing note then corroborates (agrees) or, on a vamp/loop, conflicts
        // (only cuts confidence — the end of a loop is just where it was cut).
        if let openingKey = scored.first(where: { $0.key.root.rawValue == opening }),
           openingKey.key != leader.key,
           Self.isClassicAmbiguity(leader.key.root.rawValue, openingKey.key.root.rawValue),
           corrNorm(leader.corr) - corrNorm(openingKey.corr) <= openingOverturnMargin {
            winner = openingKey
            if let closing, closing != openingKey.key.root.rawValue { lowConfidence = true }  // close disagrees
        } else {
            // No opening flip — but if the top two are a genuine near-tie on a classic ambiguity and
            // the opening doesn't disambiguate, we're honestly unsure: cut confidence so the consumer
            // gate falls quiet ("you pick").
            let shortlist = Array(scored.prefix(shortlistN))
            if shortlist.count >= 2,
               corrNorm(shortlist[0].corr) - corrNorm(shortlist[1].corr) <= contendMargin,
               Self.isClassicAmbiguity(shortlist[0].key.root.rawValue, shortlist[1].key.root.rawValue),
               favored(by: opening, shortlist[0], shortlist[1]) == nil {
                lowConfidence = true
            }
        }

        // Build candidates. The winner leads; the rest follow in histogram order. score stays on the
        // raw-correlation scale (Sanctuary's HarmonyKeyGate semantics unchanged); a low-confidence
        // near-tie is capped below the gate floor so the header/harmony falls quiet ("you pick")
        // instead of committing a coin-flip — and every non-winner is clamped ≤ the winner so the
        // result is always ranked by score even when the structural cue overruled the histogram.
        var ordered = scored
        if let wi = ordered.firstIndex(where: { $0.key == winner.key }), wi != 0 {
            ordered.insert(ordered.remove(at: wi), at: 0)
        }
        let winnerBase = min(1.0, max(0.0, ordered[0].corr))
        let winnerScore = lowConfidence ? min(winnerBase, nearTieScoreCeiling) : winnerBase
        var result: [KeyCandidate] = []
        for (i, s) in ordered.prefix(max(0, maxCandidates)).enumerated() {
            let base = min(1.0, max(0.0, s.corr))
            result.append(KeyCandidate(key: s.key,
                                       score: i == 0 ? winnerScore : min(base, winnerScore),
                                       tonicFrequency: s.tonicFreq))
        }
        return result
    }

    /// The pitch class at the take's start (`atStart: true`) or end — the boundary note's pitch
    /// class, the structural cue for "home". Within a SHORT edge window anchored at the very
    /// first onset (or last offset) the most SALIENT note (longest, then most-confident) is taken,
    /// so a brief BasicPitch transient / breath / pickup at the edge can't masquerade as the
    /// boundary while a held note a beat in does. Ties break toward the literal edge (earliest onset
    /// for the start, latest offset for the end) then `midiNote`, so the result is fully
    /// deterministic and independent of input array order. nil if there are no notes.
    static func boundaryPitchClass(_ notes: [DetectedNote], atStart: Bool, window: TimeInterval = 0.15) -> Int? {
        guard !notes.isEmpty else { return nil }
        let edge: [DetectedNote]
        if atStart {
            let anchor = notes.map(\.onsetTime).min() ?? 0
            edge = notes.filter { $0.onsetTime <= anchor + window }
        } else {
            let anchor = notes.map { $0.onsetTime + $0.duration }.max() ?? 0
            edge = notes.filter { ($0.onsetTime + $0.duration) >= anchor - window }
        }
        let pick = edge.max(by: { lhs, rhs in
            if lhs.duration != rhs.duration { return lhs.duration < rhs.duration }       // most salient first
            if lhs.confidence != rhs.confidence { return lhs.confidence < rhs.confidence }
            if atStart, lhs.onsetTime != rhs.onsetTime { return lhs.onsetTime > rhs.onsetTime } // tie → earliest onset
            if !atStart {
                let le = lhs.onsetTime + lhs.duration, re = rhs.onsetTime + rhs.duration
                if le != re { return le < re }                                            // tie → latest offset
            }
            return lhs.midiNote > rhs.midiNote                                            // final stable tie-break
        })
        return pick.map { (($0.pitchClass % 12) + 12) % 12 }
    }

    /// True when two tonic pitch classes form a classic key ambiguity a pitch histogram can't resolve:
    /// relative (±3 semitones, I vs vi), perfect fifth (±7, I vs V), or perfect fourth (±5, I vs IV).
    static func isClassicAmbiguity(_ a: Int, _ b: Int) -> Bool {
        let d = ((b - a) % 12 + 12) % 12
        return d == 3 || d == 9 || d == 7 || d == 5
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
