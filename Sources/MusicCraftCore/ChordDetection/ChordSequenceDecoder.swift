import Foundation

/// Viterbi decoding of a chord-window sequence over `NoteChordIdentifier`'s full candidate space.
///
/// **Why (2026-08-07 ceiling analysis, "6 Human" A-minor loop):** the windowed chord path labeled
/// every 0.5 s-hop window independently (per-window argmax), so one melody-contaminated window became
/// its own segment — chord-per-word churn ("Am A Em G" surviving `cleanupRuns`, whose flicker rule
/// requires identical flanks) and Am↔A / Em↔E quality flips whose major/minor decision reduced to
/// third-vs-third weight. A self-transition-favoring Viterbi decode is the single biggest documented
/// chord-accuracy lever in the literature (Cho & Bello 2014-class smoothing, ≈+22 points in
/// controlled studies): a window keeps its neighbors' label unless the evidence for switching beats
/// a switch penalty, so momentary contamination is absorbed while genuine changes (sustained better
/// evidence) still win.
///
/// Pure and deterministic: additive scores in, per-window candidate indices out. No model, no audio.
enum ChordSequenceDecoder {

    /// Cost of changing candidate label between adjacent windows (the ONE tunable). Additive, in the
    /// same units as `NoteChordIdentifier` scores. A single deviant window flanked by one chord is
    /// absorbed whenever its argmax margin over the flanking chord is < 2×penalty (switch in + switch
    /// out), so 0.12 absorbs flips up to ≈0.24 — comfortably covering the measured third-vs-third
    /// Am↔A margins — while a sustained real change accumulates margin every window and always wins.
    /// Neutral by construction on the single-chord bench fixtures (GADA / TaylorNylon): when every
    /// window argmaxes the same candidate, any penalty ≥ 0 leaves the decode identical.
    /// Verified 2026-08-08 against a pristine-HEAD worktree run of the same fixtures: GADA 100.0/100.0
    /// and TaylorNylon 99.1/99.1 root/exact on both sides, same single C→A confusion. On the
    /// multi-chord GuitarSet set the same run moved progression mean CSR 28.7% → 31.5% (still under
    /// its long-standing threshold — a documented expected-failure, unchanged in count). No key-
    /// inference claim: that metric flaps run to run on a Dictionary-ordered tie-break inside
    /// `ProgressionAnalyzer.inferKey` (see CHANGELOG 0.1.7).
    static let defaultSwitchPenalty = 0.12

    /// Magnitude of the key-aware non-diatonic penalty (second decode pass) — deliberately in the
    /// same class as `NoteChordIdentifier`'s qualityPriors (0.08–0.12): enough to make an artifact
    /// A-major in A minor need genuine C♯ evidence, small enough that a real borrowed chord with a
    /// sounding color tone still wins its window.
    static let keyPriorPenalty = 0.08

    /// Decode one window sequence. `windows[i]` is the full candidate score vector for window `i`
    /// (from `NoteChordIdentifier.candidateScores`), or nil where the window had no usable harmonic
    /// content. Returns one candidate index per window; nil windows stay nil and split the decode
    /// into independent stretches (no label continuity is claimed across silence).
    ///
    /// - Parameters:
    ///   - windows: per-window candidate score vectors (all non-nil vectors must share one length).
    ///   - switchPenalty: cost of a label change between adjacent windows (≥ 0).
    ///   - candidatePenalty: optional per-candidate penalty subtracted from EVERY window's emission
    ///     (the key-aware prior of the second decode pass); same length as the score vectors.
    /// - Returns: per-window candidate index into the score vector (argmax semantics under context).
    ///
    /// Deterministic tie-breaks mirror `identify`'s: on equal path scores prefer STAYING on the
    /// current label, then the lower candidate index — so genuinely ambiguous windows resolve the
    /// same way run-to-run.
    static func decode(windows: [[Double]?],
                       switchPenalty: Double = defaultSwitchPenalty,
                       candidatePenalty: [Double]? = nil) -> [Int?] {
        var out = [Int?](repeating: nil, count: windows.count)

        // Decode each contiguous non-nil stretch independently.
        var i = 0
        while i < windows.count {
            guard windows[i] != nil else { i += 1; continue }
            var j = i
            while j + 1 < windows.count, windows[j + 1] != nil { j += 1 }
            decodeStretch(windows: windows, range: i...j,
                          switchPenalty: switchPenalty, candidatePenalty: candidatePenalty,
                          into: &out)
            i = j + 1
        }
        return out
    }

    /// Standard max-sum Viterbi over one stretch, O(windows × candidates) via the uniform-transition
    /// trick: the best predecessor for any state is either itself (no penalty) or the globally best
    /// previous state (one penalty), because every label change costs the same.
    private static func decodeStretch(windows: [[Double]?], range: ClosedRange<Int>,
                                      switchPenalty: Double, candidatePenalty: [Double]?,
                                      into out: inout [Int?]) {
        guard let first = windows[range.lowerBound] else { return }
        let n = first.count

        func emission(_ w: Int, _ s: Int) -> Double {
            let e = windows[w]![s]
            return candidatePenalty.map { e - $0[s] } ?? e
        }

        // dp[s] = best path score ending in state s at the current window.
        var dp = (0..<n).map { emission(range.lowerBound, $0) }
        // parents[w - range.lowerBound - 1][s] = predecessor state of s at window w.
        var parents: [[Int]] = []

        if range.lowerBound < range.upperBound {
            for w in (range.lowerBound + 1)...range.upperBound {
                // Globally best previous state (lowest index on ties — deterministic).
                var bestPrev = 0
                for s in 1..<n where dp[s] > dp[bestPrev] { bestPrev = s }

                var next = [Double](repeating: 0, count: n)
                var parent = [Int](repeating: 0, count: n)
                for s in 0..<n {
                    let stay = dp[s]
                    let switched = dp[bestPrev] - switchPenalty
                    // Prefer staying on ties: absorb, don't churn.
                    if stay >= switched {
                        next[s] = emission(w, s) + stay
                        parent[s] = s
                    } else {
                        next[s] = emission(w, s) + switched
                        parent[s] = bestPrev
                    }
                }
                dp = next
                parents.append(parent)
            }
        }

        // Backtrack from the best final state (lowest index on ties).
        var bestFinal = 0
        for s in 1..<n where dp[s] > dp[bestFinal] { bestFinal = s }
        var state = bestFinal
        out[range.upperBound] = state
        for w in stride(from: range.upperBound - 1, through: range.lowerBound, by: -1) {
            state = parents[w - range.lowerBound][state]
            out[w] = state
        }
    }

    /// Per-candidate non-diatonic penalty vector for the key-aware second decode pass.
    ///
    /// A candidate whose chord tones all lie in `key`'s scale costs 0. In a MINOR key the dominant
    /// major/dominant-7 (the harmonic-minor V — E / E7 in A minor) is scored **quasi-diatonic**
    /// (0) even though its raised 7th (G♯) is outside the natural-minor scale: it is core minor-key
    /// vocabulary, and penalizing it would erase the real harmonic-minor E the ceiling analysis
    /// wants to KEEP. Everything else costs `magnitude` — so an artifact A-major inside A minor
    /// needs genuine C♯ evidence to survive the second pass, exactly the asymmetry the evidence
    /// showed (Am↔A flips driven by melody contamination, not by a sounding major third).
    static func nonDiatonicPenalty(for key: MusicalKey, magnitude: Double = keyPriorPenalty) -> [Double] {
        let scale = Set(key.scaleIntervals.map { (key.root.rawValue + $0) % 12 })
        let dominant = (key.root.rawValue + 7) % 12

        var penalty = [Double](repeating: 0, count: NoteChordIdentifier.candidateCount)
        var i = 0
        for root in 0..<12 {
            for quality in NoteChordIdentifier.candidateQualities {
                let tones = quality.intervals.map { (root + $0) % 12 }
                let diatonic = tones.allSatisfy { scale.contains($0) }
                let harmonicMinorV = key.mode == .minor && root == dominant
                    && (quality == .major || quality == .dominant7)
                penalty[i] = (diatonic || harmonicMinorV) ? 0 : magnitude
                i += 1
            }
        }
        return penalty
    }
}
