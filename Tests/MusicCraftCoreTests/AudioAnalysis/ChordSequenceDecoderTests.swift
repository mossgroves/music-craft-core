import XCTest
@testable import MusicCraftCore

/// Synthetic, deterministic tests for the 0.1.7 chord-quality fixes (the 2026-08-07 "6 Human"
/// ceiling-analysis bugs): the Viterbi window-sequence decode (`ChordSequenceDecoder`), the
/// bare-dyad power-chord guard (`AudioExtractor.bareDyadGuarded`, including its sole-run exemption),
/// and the key-aware non-diatonic prior. Theory-only; no audio, no Core ML model — histograms are
/// hand-built the same way `NoteChordIdentifierTests` builds them.
final class ChordSequenceDecoderTests: XCTestCase {

    // MARK: - Histogram helpers (mirrors NoteChordIdentifierTests)

    /// 12-element histogram with weight 1.0 on each named pitch class, plus optional extra weights.
    private func hist(_ pcs: [Int], extra: [(pc: Int, w: Double)] = []) -> [Double] {
        var h = [Double](repeating: 0, count: 12)
        for pc in pcs { h[((pc % 12) + 12) % 12] = 1.0 }
        for e in extra { h[((e.pc % 12) + 12) % 12] += e.w }
        return h
    }

    private func scores(_ pcs: [Int], bass: Int?, extra: [(pc: Int, w: Double)] = []) -> [Double]? {
        NoteChordIdentifier.candidateScores(weightedPitchClasses: hist(pcs, extra: extra), bassPitchClass: bass)
    }

    /// Decoded label index → display name, for readable assertions.
    private func name(_ label: Int?) -> String? {
        guard let label, let c = NoteChordIdentifier.candidate(at: label) else { return nil }
        return Chord(root: c.root, quality: c.quality).displayName
    }

    // Pitch classes used throughout: A=9 C=0 E=4 G=7 B=11 C♯=1 G♯=8 F=5 D=2.

    /// A clean Am window (A C E, bass A).
    private var amWindow: [Double]? { scores([9, 0, 4], bass: 9) }
    /// A clean G window (G B D, bass G).
    private var gWindow: [Double]? { scores([7, 11, 2], bass: 7) }

    /// An Am window contaminated by a sung C♯-leaning melody: the C♯ bin outweighs the C bin just
    /// enough that per-window argmax flips the quality to A MAJOR (third-vs-third weight) — the
    /// measured Am↔A flip shape from the ceiling analysis.
    private var contaminatedAmWindow: [Double]? {
        scores([9, 4], bass: 9, extra: [(pc: 0, w: 0.4), (pc: 1, w: 0.6)])
    }

    // MARK: - candidateScores API (the additive exposure the decoder rides on)

    func testCandidateScoresVectorShapeAndArgmaxMatchesIdentify() {
        let h = hist([9, 0, 4])
        guard let vec = NoteChordIdentifier.candidateScores(weightedPitchClasses: h, bassPitchClass: 9) else {
            return XCTFail("expected a score vector for a clean Am histogram")
        }
        XCTAssertEqual(vec.count, NoteChordIdentifier.candidateCount)   // 12 roots × 9 qualities = 108
        XCTAssertEqual(NoteChordIdentifier.candidateCount, 108)

        // Argmax over the vector (strictly-greater, ascending index) must agree with identify.
        var bestIdx = 0
        for i in 1..<vec.count where vec[i] > vec[bestIdx] { bestIdx = i }
        XCTAssertEqual(name(bestIdx), "Am")
        XCTAssertEqual(NoteChordIdentifier.identify(weightedPitchClasses: h, bassPitchClass: 9)?.chord.displayName, "Am")
    }

    func testCandidateScoresNilOnUnusableContent() {
        XCTAssertNil(NoteChordIdentifier.candidateScores(weightedPitchClasses: [Double](repeating: 0, count: 12), bassPitchClass: nil))
        XCTAssertNil(NoteChordIdentifier.candidateScores(weightedPitchClasses: hist([0]), bassPitchClass: 0))
    }

    // MARK: - Viterbi decode

    /// The churn fix: one contaminated window inside an Am stretch flips under per-window argmax but
    /// is absorbed by the self-transition-favoring decode — the whole stretch stays Am.
    func testViterbiAbsorbsSingleContaminatedWindow() throws {
        let contaminated = try XCTUnwrap(contaminatedAmWindow)

        // Confirm the fixture really is a flip under argmax (the bug being fixed).
        var argmax = 0
        for i in 1..<contaminated.count where contaminated[i] > contaminated[argmax] { argmax = i }
        XCTAssertEqual(name(argmax), "A", "fixture must argmax to A major for the test to mean anything")

        let windows = [amWindow, amWindow, contaminatedAmWindow, amWindow, amWindow]
        let labels = ChordSequenceDecoder.decode(windows: windows)
        XCTAssertEqual(labels.compactMap { self.name($0) }, ["Am", "Am", "Am", "Am", "Am"])
    }

    /// Neutrality on single-chord material (the GADA / TaylorNylon shape): when every window argmaxes
    /// the same candidate, the decode changes nothing at any penalty.
    func testViterbiNeutralOnSingleChordSequence() {
        let windows = [amWindow, amWindow, amWindow, amWindow]
        let labels = ChordSequenceDecoder.decode(windows: windows)
        XCTAssertEqual(labels.compactMap { self.name($0) }, ["Am", "Am", "Am", "Am"])
    }

    /// A genuine sustained change still switches: the penalty delays nothing that carries real,
    /// repeated evidence.
    func testViterbiKeepsGenuineChordChange() {
        let windows = [amWindow, amWindow, amWindow, gWindow, gWindow, gWindow]
        let labels = ChordSequenceDecoder.decode(windows: windows)
        XCTAssertEqual(labels.compactMap { self.name($0) }, ["Am", "Am", "Am", "G", "G", "G"])
    }

    /// A loop-like progression (the "6 Human" shape: a repeating minor loop with one contaminated
    /// window) decodes to the loop, not to chord-per-word churn.
    func testViterbiOnLoopLikeSequence() {
        // Am Am | F F | C C | G G | Am Am(contaminated) | F F — the loop with one dirty window.
        let f = scores([5, 9, 0], bass: 5)      // F A C
        let c = scores([0, 4, 7], bass: 0)      // C E G
        let windows = [amWindow, amWindow, f, f, c, c, gWindow, gWindow,
                       amWindow, contaminatedAmWindow, f, f]
        let labels = ChordSequenceDecoder.decode(windows: windows)
        XCTAssertEqual(labels.compactMap { self.name($0) },
                       ["Am", "Am", "F", "F", "C", "C", "G", "G", "Am", "Am", "F", "F"])
    }

    /// nil windows (no usable content) stay nil and split the decode into independent stretches —
    /// no label continuity is invented across silence.
    func testViterbiPreservesNilWindowsAndSplitsStretches() {
        let windows = [amWindow, amWindow, nil, gWindow, gWindow]
        let labels = ChordSequenceDecoder.decode(windows: windows)
        XCTAssertNil(labels[2])
        XCTAssertEqual(name(labels[0]), "Am")
        XCTAssertEqual(name(labels[1]), "Am")
        XCTAssertEqual(name(labels[3]), "G")
        XCTAssertEqual(name(labels[4]), "G")
    }

    /// A single-window stretch decodes to its own argmax (the short-clip path).
    func testViterbiSingleWindowIsArgmax() {
        let labels = ChordSequenceDecoder.decode(windows: [amWindow])
        XCTAssertEqual(name(labels[0]), "Am")
    }

    // MARK: - Bare-dyad guard (AudioExtractor.bareDyadGuarded — the run level)

    /// Build a run tuple of the shape `bareDyadGuarded` consumes.
    private func run(_ name: String, windows: ClosedRange<Int>, start: Double = 0, conf: Double = 0.9)
        -> (start: Double, chord: Chord, conf: Double, windows: ClosedRange<Int>) {
        (start, Chord(parsing: name)!, conf, windows)
    }

    /// A bare fifth dyad standing among OTHER chords no longer asserts MAJOR: the E+B run names "E5"
    /// (the phantom standalone E fix), while its flanking Am run — which does sound its third — is
    /// left exactly as decoded.
    func testBareFifthRunAmongOtherChordsNamesPowerChord() {
        let bins = [hist([9, 0, 4]), hist([4, 11]), hist([9, 0, 4])]
        let basses: [Int?] = [9, 4, 9]
        let runs = [run("Am", windows: 0...0), run("E", windows: 1...1, start: 1), run("Am", windows: 2...2, start: 2)]

        let out = AudioExtractor.bareDyadGuarded(runs: runs, bins: bins, basses: basses)
        XCTAssertEqual(out.map { $0.chord.displayName }, ["Am", "E5", "Am"])
    }

    /// A sub-floor third is not evidence: E+B with a whisper of G♯ (below the presence floor) is still
    /// a bare dyad, so the run still renames to "E5".
    func testSubFloorThirdIsStillABareDyad() {
        let bins = [hist([9, 0, 4]), hist([4, 11], extra: [(pc: 8, w: 0.1)])]   // G♯ at 10% — under the 15% floor
        let basses: [Int?] = [9, 4]
        let runs = [run("Am", windows: 0...0), run("E", windows: 1...1, start: 1)]

        let out = AudioExtractor.bareDyadGuarded(runs: runs, bins: bins, basses: basses)
        XCTAssertEqual(out.map { $0.chord.displayName }, ["Am", "E5"])
    }

    /// A REAL third keeps the triad name: a run whose window sounds G♯ stays "E" — the guard only
    /// fires when no third sounds in ANY window of the run.
    func testSoundingThirdKeepsTriadName() {
        let bins = [hist([9, 0, 4]), hist([4, 8, 11])]
        let basses: [Int?] = [9, 4]
        let runs = [run("Am", windows: 0...0), run("E", windows: 1...1, start: 1)]

        let out = AudioExtractor.bareDyadGuarded(runs: runs, bins: bins, basses: basses)
        XCTAssertEqual(out.map { $0.chord.displayName }, ["Am", "E"])
    }

    /// One window of the run sounding a third is enough to keep the triad name — the guard asks
    /// "did ANY window of this run sound a third?", not "did every window".
    func testOneThirdBearingWindowKeepsTheRunsTriadName() {
        let bins = [hist([9, 0, 4]), hist([4, 11]), hist([4, 8, 11])]
        let basses: [Int?] = [9, 4, 4]
        let runs = [run("Am", windows: 0...0), run("E", windows: 1...2, start: 1)]

        let out = AudioExtractor.bareDyadGuarded(runs: runs, bins: bins, basses: basses)
        XCTAssertEqual(out.map { $0.chord.displayName }, ["Am", "E"])
    }

    /// **The sole-run exemption** (2026-08-08 bench evidence): a take that is ONE chord is never
    /// renamed, however bare its dyad. Four of the nineteen sustained TaylorNylon G takes transcribe
    /// as a pure D+G dyad with no B anywhere — a nylon-string transcription miss, not a real power
    /// chord — and renaming them cost 3.7 points of bench exact accuracy. Without other chords to
    /// judge against, the guard has no context and stays out.
    func testSoleRunIsNeverRenamedEvenWhenBare() {
        let bins = [hist([7, 2]), hist([7, 2])]   // G + D across both windows, no B anywhere
        let basses: [Int?] = [7, 7]
        let runs = [run("G", windows: 0...1)]

        let out = AudioExtractor.bareDyadGuarded(runs: runs, bins: bins, basses: basses)
        XCTAssertEqual(out.map { $0.chord.displayName }, ["G"])
    }

    /// The same bare G run DOES rename once the take carries another chord — proving the exemption is
    /// about missing context, not about the G evidence itself.
    func testSameBareRunRenamesOnceThereIsContext() {
        let bins = [hist([7, 2]), hist([9, 0, 4])]
        let basses: [Int?] = [7, 9]
        let runs = [run("G", windows: 0...0), run("Am", windows: 1...1, start: 1)]

        let out = AudioExtractor.bareDyadGuarded(runs: runs, bins: bins, basses: basses)
        XCTAssertEqual(out.map { $0.chord.displayName }, ["G5", "Am"])
    }

    /// The guard never touches a non-major/minor run — a decoded sus/7th name is left alone even with
    /// no third sounding (its own quality prior already had to earn the name).
    func testNonTriadRunIsLeftAlone() {
        let bins = [hist([9, 0, 4]), hist([4, 9, 11])]
        let basses: [Int?] = [9, 4]
        let runs = [run("Am", windows: 0...0), run("Esus4", windows: 1...1, start: 1)]

        let out = AudioExtractor.bareDyadGuarded(runs: runs, bins: bins, basses: basses)
        XCTAssertEqual(out.map { $0.chord.displayName }, ["Am", "Esus4"])
    }

    /// `identify` keeps its 0.1.0 behaviour — the guard is NOT applied to a lone histogram, because a
    /// single histogram carries no context (see the type doc on `NoteChordIdentifier`).
    func testIdentifyStillNamesABareDyadByCandidateOrdering() {
        XCTAssertEqual(NoteChordIdentifier.identify(weightedPitchClasses: hist([4, 11]), bassPitchClass: 4)?.chord.displayName, "E")
        XCTAssertEqual(NoteChordIdentifier.identify(weightedPitchClasses: hist([4, 8, 11]), bassPitchClass: 4)?.chord.displayName, "E")
        XCTAssertEqual(NoteChordIdentifier.identify(weightedPitchClasses: hist([4, 7, 11]), bassPitchClass: 4)?.chord.displayName, "Em")
    }

    /// The guard's evidence primitive agrees with the floor semantics.
    func testThirdPassesHelper() {
        XCTAssertFalse(NoteChordIdentifier.thirdPasses(root: 4, weightedPitchClasses: hist([4, 11])))
        XCTAssertTrue(NoteChordIdentifier.thirdPasses(root: 4, weightedPitchClasses: hist([4, 8, 11])))   // major 3rd
        XCTAssertTrue(NoteChordIdentifier.thirdPasses(root: 4, weightedPitchClasses: hist([4, 7, 11])))   // minor 3rd
    }

    /// The power naming carries a usable confidence (clamped shared-formula score, like every other
    /// candidate).
    func testPowerChordConfidenceInRange() throws {
        let p = try XCTUnwrap(NoteChordIdentifier.powerChord(root: 4, weightedPitchClasses: hist([4, 11]), bassPitchClass: 4))
        XCTAssertGreaterThan(p.confidence, 0)
        XCTAssertLessThanOrEqual(p.confidence, 1)
        XCTAssertEqual(p.chord.quality, .power)
        XCTAssertEqual(p.chord.notes, [.E, .B])
    }

    // MARK: - Relative-minor guard (AudioExtractor.relativeMinorGuarded — the 2026-08-13 Rodanthe fix)

    /// Score vectors for the guard's windows, built the same way production builds them.
    private func vectors(bins: [[Double]], basses: [Int?]) -> [[Double]?] {
        (0..<bins.count).map { NoteChordIdentifier.candidateScores(weightedPitchClasses: bins[$0], bassPitchClass: basses[$0]) }
    }

    /// **The transition-blip shape** (Rodanthe 4.5 s, measured 2026-08-13): a single Bm7 window whose
    /// evidence is really D-plus-ring-over (F♯ .41 / D .37 / B .12 / A .10, one fleeting B bass)
    /// between a D run and a G run. The B never holds the bass for a beat and the D neighbor covers
    /// the run's upper structure, so the blip renames to the neighbor's D — which the cleanup
    /// re-collapse then absorbs.
    func testSubstitutionBlipRenamesToNeighborRelativeMajor() {
        let bins = [hist([2, 6, 9]),
                    hist([], extra: [(pc: 6, w: 1.0), (pc: 2, w: 0.9), (pc: 11, w: 0.29), (pc: 9, w: 0.24)]),
                    hist([7, 11, 2])]
        let basses: [Int?] = [2, 11, 7]
        let runs = [run("D", windows: 0...0), run("Bm7", windows: 1...1, start: 0.5), run("G", windows: 2...2, start: 1)]

        let out = AudioExtractor.relativeMinorGuarded(runs: runs, bins: bins, basses: basses,
                                                      scoreVectors: vectors(bins: bins, basses: basses))
        XCTAssertEqual(out.map { $0.chord.displayName }, ["D", "D", "G"])
    }

    /// **The stolen-segment shape** (Rodanthe chorus A at 45.5/51.5/63.5 s): the substitution took the
    /// ENTIRE true A segment — F♯m7 flanked by D on both sides, no A neighbor to defer to. The run's
    /// own summed windows sound the full A triad over an A bass (A 1.0 / C♯ .48 / F♯ .43 / E .33 per
    /// window, bass A), so cover evidence renames it to the relative major itself and the real chord
    /// reappears as its own segment.
    func testStolenMajorSegmentRenamedByCoverEvidence() {
        let blend: [Double] = hist([], extra: [(pc: 9, w: 1.0), (pc: 1, w: 0.48), (pc: 6, w: 0.43), (pc: 4, w: 0.33), (pc: 2, w: 0.3)])
        let bins = [hist([2, 6, 9]), blend, blend, hist([2, 6, 9])]
        let basses: [Int?] = [2, 9, 9, 2]
        let runs = [run("D", windows: 0...0), run("F♯m7", windows: 1...2, start: 0.5), run("D", windows: 3...3, start: 1.5)]

        let out = AudioExtractor.relativeMinorGuarded(runs: runs, bins: bins, basses: basses,
                                                      scoreVectors: vectors(bins: bins, basses: basses))
        XCTAssertEqual(out.map { $0.chord.displayName }, ["D", "A", "D"])
        XCTAssertGreaterThan(out[1].conf, 0)
    }

    /// **The bass separator, keep side** (Kill Devil Hills 55.5 s): the same A-C♯-E-over-weak-F♯
    /// histogram shape as a substitution — but the F♯ HOLDS THE BASS in both windows (≈ a beat), which
    /// is exactly what every real short minor in the corpus did and no artifact ever did. Kept.
    func testBassSupportedShortMinorIsKept() {
        let voicing: [Double] = hist([], extra: [(pc: 9, w: 1.0), (pc: 1, w: 0.73), (pc: 4, w: 0.41), (pc: 6, w: 0.24)])
        let bins = [hist([9, 1, 4]), voicing, voicing, hist([9, 1, 4])]
        let basses: [Int?] = [9, 6, 6, 9]
        let runs = [run("A", windows: 0...0), run("F♯m7", windows: 1...2, start: 0.5), run("A", windows: 3...3, start: 1.5)]

        let out = AudioExtractor.relativeMinorGuarded(runs: runs, bins: bins, basses: basses,
                                                      scoreVectors: vectors(bins: bins, basses: basses))
        XCTAssertEqual(out.map { $0.chord.displayName }, ["A", "F♯m7", "A"])
    }

    /// **Sustained minors are structurally exempt** — every sustained chord in the Rodanthe
    /// measurement scored 5/5, so the guard never reads a run longer than
    /// `relativeMinorGuardMaxWindows` (Kill Devil Hills' 4-window F♯m7 at 13.5 s stays, even though
    /// its F♯ weight is tiny and its windows would otherwise qualify for cover evidence).
    func testSustainedMinorRunIsExempt() {
        let blend: [Double] = hist([], extra: [(pc: 9, w: 1.0), (pc: 1, w: 0.9), (pc: 4, w: 0.55), (pc: 6, w: 0.25)])
        let bins = [hist([9, 1, 4]), blend, blend, blend, blend]
        let basses: [Int?] = [9, 9, 9, 9, 9]
        let runs = [run("A", windows: 0...0), run("F♯m7", windows: 1...4, start: 0.5)]

        let out = AudioExtractor.relativeMinorGuarded(runs: runs, bins: bins, basses: basses,
                                                      scoreVectors: vectors(bins: bins, basses: basses))
        XCTAssertEqual(out.map { $0.chord.displayName }, ["A", "F♯m7"])
    }

    /// **The minor→minor boundary is not a substitution** (Romance de Amor 15.5 s): the Em→Am handoff
    /// window blends {E,G,B}+{A,C,E} ⊇ the C triad, but no C is ever in the bass and no C neighbor
    /// exists — renaming it to a C the piece never plays would trade an honest boundary for an
    /// out-of-progression name. The cover test's bass requirement keeps it Am7.
    func testMinorBoundaryBlendWithoutRelativeMajorBassIsKept() {
        let blend: [Double] = hist([], extra: [(pc: 9, w: 1.0), (pc: 4, w: 0.97), (pc: 0, w: 0.7), (pc: 7, w: 0.67)])
        let bins = [hist([4, 7, 11]), blend, hist([9, 0, 4])]
        let basses: [Int?] = [4, 4, 9]
        let runs = [run("Em", windows: 0...0), run("Am7", windows: 1...1, start: 0.5), run("Am", windows: 2...2, start: 1)]

        let out = AudioExtractor.relativeMinorGuarded(runs: runs, bins: bins, basses: basses,
                                                      scoreVectors: vectors(bins: bins, basses: basses))
        XCTAssertEqual(out.map { $0.chord.displayName }, ["Em", "Am7", "Am"])
    }

    /// **A minor7 stretch inside its own minor section stays put** (Kill Devil Hills 50–51.5 s): the
    /// real Bm section decodes Bm–Bm7–Bm with F♯ in the bass throughout (the fifth, not the relative
    /// major's root). No D bass, no D neighbor — the guard must not carve a D out of the middle of a
    /// real Bm, and the cleanup flicker-absorb then folds Bm7 back into Bm as before.
    func testMinorSevenInsideSameRootMinorSectionIsKept() {
        let seven: [Double] = hist([], extra: [(pc: 2, w: 1.0), (pc: 6, w: 0.8), (pc: 11, w: 0.64), (pc: 9, w: 0.33)])
        let bins = [hist([11, 2, 6]), seven, seven, seven, hist([11, 2, 6])]
        let basses: [Int?] = [6, 6, 6, 6, 6]
        let runs = [run("Bm", windows: 0...0), run("Bm7", windows: 1...3, start: 0.5), run("Bm", windows: 4...4, start: 2)]

        let out = AudioExtractor.relativeMinorGuarded(runs: runs, bins: bins, basses: basses,
                                                      scoreVectors: vectors(bins: bins, basses: basses))
        XCTAssertEqual(out.map { $0.chord.displayName }, ["Bm", "Bm7", "Bm"])
    }

    /// **Sole-run exemption**, same conservative posture as the bare-dyad guard and `cleanupRuns`:
    /// a take that is one minor chord is never renamed, whatever its histogram looks like.
    func testSoleMinorRunIsNeverRenamed() {
        let blend: [Double] = hist([], extra: [(pc: 9, w: 1.0), (pc: 1, w: 0.48), (pc: 6, w: 0.43), (pc: 4, w: 0.33)])
        let bins = [blend, blend]
        let basses: [Int?] = [9, 9]
        let runs = [run("F♯m7", windows: 0...1)]

        let out = AudioExtractor.relativeMinorGuarded(runs: runs, bins: bins, basses: basses,
                                                      scoreVectors: vectors(bins: bins, basses: basses))
        XCTAssertEqual(out.map { $0.chord.displayName }, ["F♯m7"])
    }

    /// The guard's evidence primitive shares `identify`'s presence-floor semantics: the full major
    /// triad must sound — a missing or sub-floor tone fails it.
    func testMajorTriadPresentHelper() {
        XCTAssertTrue(NoteChordIdentifier.majorTriadPresent(root: 2, weightedPitchClasses: hist([2, 6, 9])))
        XCTAssertFalse(NoteChordIdentifier.majorTriadPresent(root: 2, weightedPitchClasses: hist([2, 6])))
        XCTAssertFalse(NoteChordIdentifier.majorTriadPresent(root: 2, weightedPitchClasses: hist([2, 6], extra: [(pc: 9, w: 0.1)])))
        XCTAssertFalse(NoteChordIdentifier.majorTriadPresent(root: 2, weightedPitchClasses: hist([2, 3, 9])))
    }

    // MARK: - Key-aware non-diatonic prior

    /// In A minor: diatonic chords (Am, F, G, C…) cost 0; the harmonic-minor V (E, E7) is
    /// quasi-diatonic and costs 0; the artifact A MAJOR (needs C♯) is penalized.
    func testNonDiatonicPenaltyInAMinor() {
        let aMinor = MusicalKey(root: .A, mode: .minor)
        let penalty = ChordSequenceDecoder.nonDiatonicPenalty(for: aMinor)

        func p(_ root: NoteName, _ quality: ChordQuality) -> Double {
            let qIdx = NoteChordIdentifier.candidateQualities.firstIndex(of: quality)!
            return penalty[root.rawValue * NoteChordIdentifier.candidateQualities.count + qIdx]
        }

        XCTAssertEqual(p(.A, .minor), 0)          // i
        XCTAssertEqual(p(.F, .major), 0)          // VI
        XCTAssertEqual(p(.G, .major), 0)          // VII (natural minor)
        XCTAssertEqual(p(.C, .major), 0)          // III
        XCTAssertEqual(p(.E, .major), 0)          // V of minor — quasi-diatonic (harmonic minor)
        XCTAssertEqual(p(.E, .dominant7), 0)      // V7 of minor — quasi-diatonic
        XCTAssertEqual(p(.E, .minor), 0)          // v (natural minor) is diatonic too
        XCTAssertGreaterThan(p(.A, .major), 0)    // artifact A major needs genuine C♯ evidence
        XCTAssertGreaterThan(p(.B, .major), 0)    // fully chromatic here
    }

    /// In C major: the plain diatonic set costs 0; borrowed chords are penalized.
    func testNonDiatonicPenaltyInCMajor() {
        let cMajor = MusicalKey(root: .C, mode: .major)
        let penalty = ChordSequenceDecoder.nonDiatonicPenalty(for: cMajor)

        func p(_ root: NoteName, _ quality: ChordQuality) -> Double {
            let qIdx = NoteChordIdentifier.candidateQualities.firstIndex(of: quality)!
            return penalty[root.rawValue * NoteChordIdentifier.candidateQualities.count + qIdx]
        }

        XCTAssertEqual(p(.C, .major), 0)
        XCTAssertEqual(p(.A, .minor), 0)
        XCTAssertEqual(p(.G, .dominant7), 0)
        XCTAssertGreaterThan(p(.C, .minor), 0)    // borrowed i
        XCTAssertGreaterThan(p(.E, .major), 0)    // V/vi — chromatic here
    }

    /// The prior's asymmetry, isolated on a single window (no flanks, no switch penalty in play):
    /// a *marginally* major-leaning contaminated window (C♯ barely outweighing C — melody
    /// contamination, not harmony) reads A without the prior but Am WITH it, while a window with
    /// genuine full-strength C♯ evidence keeps its A-major name straight through the prior.
    func testKeyPriorFlipsMarginalArtifactMajorButKeepsRealEvidence() {
        let aMinor = MusicalKey(root: .A, mode: .minor)
        let penalty = ChordSequenceDecoder.nonDiatonicPenalty(for: aMinor)

        // Marginal: A=1.0 E=1.0 C=0.5 C♯=0.6 — the A-vs-Am margin (~0.04) is melody-contamination
        // sized, inside the prior's 0.08 reach.
        let marginal = scores([9, 4], bass: 9, extra: [(pc: 0, w: 0.5), (pc: 1, w: 0.6)])
        XCTAssertEqual(ChordSequenceDecoder.decode(windows: [marginal]).compactMap { self.name($0) }, ["A"])
        XCTAssertEqual(ChordSequenceDecoder.decode(windows: [marginal], candidatePenalty: penalty)
            .compactMap { self.name($0) }, ["Am"])

        // Genuine: a full-strength C♯ with only trace C — real harmonic evidence dwarfs the prior.
        let genuine = scores([9, 1, 4], bass: 9, extra: [(pc: 0, w: 0.1)])
        XCTAssertEqual(ChordSequenceDecoder.decode(windows: [genuine], candidatePenalty: penalty)
            .compactMap { self.name($0) }, ["A"])
    }

    /// End-to-end shape of the second pass: the harmonic-minor V survives the prior (E with a real
    /// G♯ inside an A-minor loop) — V-of-minor is quasi-diatonic, not an artifact.
    func testKeyPriorKeepsHarmonicMinorV() {
        let aMinor = MusicalKey(root: .A, mode: .minor)
        let penalty = ChordSequenceDecoder.nonDiatonicPenalty(for: aMinor)
        let e = scores([4, 8, 11], bass: 4)   // E G♯ B — a real E major triad
        let labels = ChordSequenceDecoder.decode(windows: [amWindow, amWindow, e, e],
                                                 candidatePenalty: penalty)
        XCTAssertEqual(labels.compactMap { self.name($0) }, ["Am", "Am", "E", "E"])
    }
}
