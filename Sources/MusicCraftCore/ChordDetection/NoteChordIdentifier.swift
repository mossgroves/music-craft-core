import Foundation

/// Names a chord **directly from notes** — a weighted pitch-class histogram plus an optional bass
/// pitch class — with no FFT, no chroma template library, and no overtone/harmonic suppression.
/// Pure music theory over arrays + the `Chord`/`ChordQuality`/`NoteName` types.
///
/// This is the Phase 2 "note-native" route: feed it `Σ duration×velocity` per pitch class from a
/// `BasicPitchTranscriber` transcription (and the lowest note's pitch class as bass) and it returns
/// a named chord. It is deliberately additive and unwired — `AudioExtractor` / `ChordDetector` /
/// `Result` are untouched.
///
/// **0.1.7 additions (the 2026-08-07 ceiling-analysis fixes):**
/// - `candidateScores(...)` exposes the FULL per-candidate score vector (12 roots ×
///   `candidateQualities.count` qualities) so a sequence decoder (`ChordSequenceDecoder`) can pick
///   labels in context instead of per-window argmax — the Viterbi lever from the chord literature.
/// - `thirdPasses` / `powerChord` are the **bare-dyad guard**'s two primitives: "is either third of
///   this root actually sounding?" and "name this root as a power chord, scored comparably". They
///   exist because a bare root+fifth dyad falls out as MAJOR on candidate ordering alone (major sits
///   first in `candidateQualities` and replacement is strictly-greater) — the phantom standalone
///   E/A majors the "6 Human" A-minor loop showed.
///
///   The guard ITSELF lives in `AudioExtractor.bareDyadGuarded`, not here, and deliberately so:
///   deciding that a missing third means a real dyad rather than a transcription miss needs context
///   this single-histogram namer does not have. Measured 2026-08-08 — four of the nineteen sustained
///   TaylorNylon G takes transcribe as a pure D+G dyad with no B in any window (nylon strings have
///   weak 3rd harmonics), and vetoing quality inside `identify` renamed all four to "G5" against a
///   ground truth of G major, costing 3.7 points of bench exact accuracy. `identify` therefore keeps
///   its 0.1.0 behaviour — pure argmax over the candidate space, no quality veto. Do not re-add the
///   veto here without new evidence.
public enum NoteChordIdentifier {

    /// The fixture vocabulary (GADA / TaylorNylon). 9ths are intentionally omitted for now; add them
    /// when the bench needs them. `.power` is deliberately NOT a candidate — it never competes in
    /// scoring (a bare fifth is a *subset* of nearly every quality and would over-fire); it is only
    /// emitted by the bare-dyad guard when no third supports a major/minor claim.
    ///
    /// Public so consumers of `candidateScores` can interpret the vector's quality axis.
    public static let candidateQualities: [ChordQuality] = [
        .major, .minor, .dominant7, .major7, .minor7, .sus2, .sus4, .diminished, .augmented,
    ]

    /// Number of candidates in a `candidateScores` vector: 12 roots × `candidateQualities.count`.
    public static var candidateCount: Int { 12 * candidateQualities.count }

    /// Decompose a flat `candidateScores` index (`root * candidateQualities.count + qualityIndex`)
    /// into its (root, quality) pair. Returns nil for an out-of-range index.
    public static func candidate(at index: Int) -> (root: NoteName, quality: ChordQuality)? {
        guard index >= 0, index < candidateCount,
              let root = NoteName(rawValue: index / candidateQualities.count) else { return nil }
        return (root, candidateQualities[index % candidateQualities.count])
    }

    // Scoring knobs (kept conservative — see the per-clause comments in `identify`).
    private static let presenceFraction = 0.15   // a chord tone counts as "present" at ≥15% of the max bin
    private static let missingPenalty = 0.5       // per chord tone that is absent
    private static let extraPenalty = 0.3         // × fraction of weight sounding outside the chord
    private static let complexityPenalty = 0.01   // × interval count — breaks near-ties toward fewer tones
    private static let bassBonus = 0.1            // when the candidate root == the bass pitch class

    /// Per-quality prior (subtracted from the score). Plain major/minor are the overwhelmingly common
    /// shapes in this repertoire; augmented, suspended, and 7th names were over-fired on real guitar
    /// (on-device reads showed spurious `C+`, `G♯+`, `Esus2`, `Bsus4`, `Gmaj7`) when their distinguishing
    /// tone — the ♯5, the sus 2nd/4th, the added 7th — was only weakly present (a passing tone, an
    /// overtone, or a Basic Pitch near-miss). A prior makes a colored name win only when its color tone
    /// carries enough weight to overcome it; with a full-strength color tone the colored chord still
    /// wins by a wide margin (the synthetic unit tests). Augmented is penalized hardest — it is rare in
    /// folk/singer-songwriter guitar and was the worst offender. Tuned against the labeled bench
    /// (GADA / TaylorNylon) so genuine colored chords there are unaffected.
    private static func qualityPrior(_ q: ChordQuality) -> Double {
        switch q {
        case .major, .minor:       return 0.0
        case .power:               return 0.0   // guard-only naming; never competes in the candidate space
        case .sus2, .sus4:         return 0.12
        case .dominant7, .minor7:  return 0.10
        case .major7:              return 0.12
        case .diminished:          return 0.08
        case .augmented:           return 0.20
        default:                   return 0.10
        }
    }

    /// Shared per-candidate scorer — the single formula behind `identify`, `candidateScores`, and the
    /// power-chord naming, so argmax and sequence-decoded paths can never drift apart.
    private static func score(root: Int, quality: ChordQuality,
                              pcs: [Double], total: Double, presenceFloor: Double,
                              rootIsBass: Bool) -> Double {
        let chordSet = Set(quality.intervals.map { (root + $0) % 12 })
        var chordWeight = 0.0
        var missing = 0
        for pc in chordSet {
            chordWeight += pcs[pc]
            if pcs[pc] < presenceFloor { missing += 1 }
        }
        let inRatio = chordWeight / total           // fraction of weight on chord tones
        let extraRatio = 1.0 - inRatio              // fraction of weight outside the chord

        var s = inRatio
        s -= missingPenalty * Double(missing)       // don't reward chords whose tones aren't sounding
        s -= extraPenalty * extraRatio              // penalize weight that doesn't belong to the chord
        s -= complexityPenalty * Double(quality.intervals.count) // prefer fewer tones on near-ties
        s -= qualityPrior(quality)                  // bias against rare/colored names; favors plain triads on near-ties
        if rootIsBass { s += bassBonus }            // bass is a root tiebreaker/bonus only
        return s
    }

    /// Normalized histogram context shared by the public entry points. Returns nil when the histogram
    /// carries no usable harmonic content (same guards `identify` has always had).
    private static func context(weightedPitchClasses: [Double], bassPitchClass: Int?)
        -> (pcs: [Double], total: Double, presenceFloor: Double, bass: Int?)? {
        guard weightedPitchClasses.count >= 12 else { return nil }
        let pcs = Array(weightedPitchClasses.prefix(12)).map { max(0, $0) }
        let total = pcs.reduce(0, +)
        guard total > 0 else { return nil }
        let maxWeight = pcs.max() ?? 0
        let presenceFloor = maxWeight * presenceFraction

        // Need at least two distinct pitch classes to talk about a chord.
        let distinctPresent = pcs.filter { $0 >= presenceFloor }.count
        guard distinctPresent >= 2 else { return nil }

        let bass = bassPitchClass.map { (($0 % 12) + 12) % 12 }
        return (pcs, total, presenceFloor, bass)
    }

    /// The FULL per-candidate score vector for one histogram: `candidateCount` entries indexed
    /// `root * candidateQualities.count + qualityIndex` (roots ascending 0–11, qualities in
    /// `candidateQualities` order). Scores are the same additive values `identify` argmaxes over —
    /// they can be negative; relative order is what matters. Returns nil when the histogram has no
    /// usable harmonic content (the same guards as `identify`).
    ///
    /// Additive API (2026-08-07): exists so `ChordSequenceDecoder` can Viterbi-decode a window
    /// SEQUENCE over the whole candidate space instead of committing to a per-window argmax — the
    /// single biggest documented chord-accuracy lever (Cho & Bello-class self-transition smoothing).
    public static func candidateScores(weightedPitchClasses: [Double], bassPitchClass: Int?) -> [Double]? {
        guard let ctx = context(weightedPitchClasses: weightedPitchClasses, bassPitchClass: bassPitchClass) else {
            return nil
        }
        var scores = [Double](repeating: 0, count: candidateCount)
        var i = 0
        for root in 0..<12 {
            let rootIsBass = ctx.bass == root
            for quality in candidateQualities {
                scores[i] = score(root: root, quality: quality,
                                  pcs: ctx.pcs, total: ctx.total, presenceFloor: ctx.presenceFloor,
                                  rootIsBass: rootIsBass)
                i += 1
            }
        }
        return scores
    }

    /// True when EITHER third (major or minor) of `root` passes the presence floor of this histogram.
    /// The bare-dyad guard's evidence test: a major/minor claim needs a third that is actually
    /// sounding, not just implied by candidate ordering. Internal so `AudioExtractor.bareDyadGuarded`
    /// can ask it of every window in a decoded run.
    static func thirdPasses(root: Int, weightedPitchClasses: [Double]) -> Bool {
        guard let ctx = context(weightedPitchClasses: weightedPitchClasses, bassPitchClass: nil) else {
            return false
        }
        let r = ((root % 12) + 12) % 12
        return ctx.pcs[(r + 4) % 12] >= ctx.presenceFloor || ctx.pcs[(r + 3) % 12] >= ctx.presenceFloor
    }

    /// Score + build the `.power` naming for `root` over this histogram (the bare-dyad guard's
    /// replacement chord). Uses the shared scoring formula so its confidence is comparable to the
    /// competing candidates'. Internal for the same reason as `thirdPasses`.
    static func powerChord(root: Int, weightedPitchClasses: [Double], bassPitchClass: Int?) -> (chord: Chord, confidence: Double)? {
        guard let ctx = context(weightedPitchClasses: weightedPitchClasses, bassPitchClass: bassPitchClass),
              let rootNote = NoteName(rawValue: ((root % 12) + 12) % 12) else { return nil }
        let s = score(root: rootNote.rawValue, quality: .power,
                      pcs: ctx.pcs, total: ctx.total, presenceFloor: ctx.presenceFloor,
                      rootIsBass: ctx.bass == rootNote.rawValue)
        let confidence = min(1.0, max(0.0, s))
        let notes = ChordQuality.power.intervals.compactMap { NoteName(rawValue: (rootNote.rawValue + $0) % 12) }
        return (Chord(root: rootNote, quality: .power, confidence: confidence, notes: notes), confidence)
    }

    /// Name a chord from a 12-element weighted pitch-class histogram and an optional bass pitch
    /// class. `weightedPitchClasses[pc]` is the summed salience of that pitch class (e.g.
    /// Σ duration×velocity). Returns nil if there is no usable harmonic content.
    ///
    /// The chord is named in **root position** to match the fixture labels; `bassPitchClass` is used
    /// only as a root tiebreaker/bonus. (It would make slash/inversion output an easy later add:
    /// emit `root/<bass>` when the bass is a non-root chord tone.)
    ///
    /// Unchanged in 0.1.7: a bare root+fifth dyad still names major here (candidate ordering), because
    /// vetoing that without sequence context misfires on sparse nylon voicings. The veto is the
    /// bare-dyad guard and it lives in `AudioExtractor.bareDyadGuarded` — see the type doc above.
    public static func identify(weightedPitchClasses: [Double], bassPitchClass: Int?) -> (chord: Chord, confidence: Double)? {
        guard let ctx = context(weightedPitchClasses: weightedPitchClasses, bassPitchClass: bassPitchClass) else {
            return nil
        }

        var best: (root: Int, quality: ChordQuality, score: Double)?

        // Iterate roots ascending and qualities in a fixed order; only replace on a STRICTLY greater
        // score. This makes genuinely ambiguous sets deterministic toward the lowest root / earliest
        // quality (e.g. C-D-G → Csus2 not Gsus4; C-E-G♯ → C+ among the symmetric augmenteds).
        for root in 0..<12 {
            let rootIsBass = ctx.bass == root
            for quality in candidateQualities {
                let s = score(root: root, quality: quality,
                              pcs: ctx.pcs, total: ctx.total, presenceFloor: ctx.presenceFloor,
                              rootIsBass: rootIsBass)
                if best == nil || s > best!.score {
                    best = (root, quality, s)
                }
            }
        }

        guard let pick = best, let rootNote = NoteName(rawValue: pick.root) else { return nil }

        let notes = pick.quality.intervals.compactMap { NoteName(rawValue: (pick.root + $0) % 12) }
        let confidence = min(1.0, max(0.0, pick.score))
        let chord = Chord(root: rootNote, quality: pick.quality, confidence: confidence, notes: notes)
        return (chord, confidence)
    }
}
