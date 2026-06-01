import Foundation

/// Names a chord **directly from notes** — a weighted pitch-class histogram plus an optional bass
/// pitch class — with no FFT, no chroma template library, and no overtone/harmonic suppression.
/// Pure music theory over arrays + the `Chord`/`ChordQuality`/`NoteName` types.
///
/// This is the Phase 2 "note-native" route: feed it `Σ duration×velocity` per pitch class from a
/// `BasicPitchTranscriber` transcription (and the lowest note's pitch class as bass) and it returns
/// a named chord. It is deliberately additive and unwired — `AudioExtractor` / `ChordDetector` /
/// `Result` are untouched.
public enum NoteChordIdentifier {

    /// The fixture vocabulary (GADA / TaylorNylon). 9ths / power chords are intentionally omitted
    /// for now; add them when the bench needs them.
    static let candidateQualities: [ChordQuality] = [
        .major, .minor, .dominant7, .major7, .minor7, .sus2, .sus4, .diminished, .augmented,
    ]

    // Scoring knobs (kept conservative — see the per-clause comments in `identify`).
    private static let presenceFraction = 0.15   // a chord tone counts as "present" at ≥15% of the max bin
    private static let missingPenalty = 0.5       // per chord tone that is absent
    private static let extraPenalty = 0.3         // × fraction of weight sounding outside the chord
    private static let complexityPenalty = 0.01   // × interval count — breaks near-ties toward fewer tones
    private static let bassBonus = 0.1            // when the candidate root == the bass pitch class

    /// Name a chord from a 12-element weighted pitch-class histogram and an optional bass pitch
    /// class. `weightedPitchClasses[pc]` is the summed salience of that pitch class (e.g.
    /// Σ duration×velocity). Returns nil if there is no usable harmonic content.
    ///
    /// The chord is named in **root position** to match the fixture labels; `bassPitchClass` is used
    /// only as a root tiebreaker/bonus. (It would make slash/inversion output an easy later add:
    /// emit `root/<bass>` when the bass is a non-root chord tone.)
    public static func identify(weightedPitchClasses: [Double], bassPitchClass: Int?) -> (chord: Chord, confidence: Double)? {
        guard weightedPitchClasses.count >= 12 else { return nil }
        let pcs = Array(weightedPitchClasses.prefix(12)).map { max(0, $0) }
        let total = pcs.reduce(0, +)
        guard total > 0 else { return nil }
        let maxWeight = pcs.max() ?? 0
        let presenceFloor = maxWeight * presenceFraction

        // Need at least two distinct pitch classes to talk about a chord.
        let distinctPresent = pcs.filter { $0 >= presenceFloor }.count
        guard distinctPresent >= 2 else { return nil }

        var best: (root: Int, quality: ChordQuality, score: Double)?

        // Iterate roots ascending and qualities in a fixed order; only replace on a STRICTLY greater
        // score. This makes genuinely ambiguous sets deterministic toward the lowest root / earliest
        // quality (e.g. C-D-G → Csus2 not Gsus4; C-E-G♯ → C+ among the symmetric augmenteds).
        for root in 0..<12 {
            let rootIsBass = (bassPitchClass.map { ((($0 % 12) + 12) % 12) == root } ?? false)
            for quality in candidateQualities {
                let chordPCs = quality.intervals.map { (root + $0) % 12 }
                let chordSet = Set(chordPCs)

                var chordWeight = 0.0
                var missing = 0
                for pc in chordSet {
                    chordWeight += pcs[pc]
                    if pcs[pc] < presenceFloor { missing += 1 }
                }
                let inRatio = chordWeight / total           // fraction of weight on chord tones
                let extraRatio = 1.0 - inRatio              // fraction of weight outside the chord

                var score = inRatio
                score -= missingPenalty * Double(missing)   // don't reward chords whose tones aren't sounding
                score -= extraPenalty * extraRatio          // penalize weight that doesn't belong to the chord
                score -= complexityPenalty * Double(quality.intervals.count) // prefer fewer tones on near-ties
                if rootIsBass { score += bassBonus }        // bass is a root tiebreaker/bonus only

                if best == nil || score > best!.score {
                    best = (root, quality, score)
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
