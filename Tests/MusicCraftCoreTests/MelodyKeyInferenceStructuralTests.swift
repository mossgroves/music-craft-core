import XCTest
@testable import MusicCraftCore

/// Phase-1 structural re-rank tests (2026-06-18; docs/specs/tonic-key-detection-redesign.md).
/// The histogram is order-blind; these pin the cues that break a near-tie — the note you OPEN on
/// (the strongest), corroborated by the note you END on — and the "unsure → you pick" abstain on a
/// genuine fifth/fourth/relative coin-flip. The headline case is Chris's D-then-G drone read as G.
final class MelodyKeyInferenceStructuralTests: XCTestCase {

    private func note(_ midi: Int, _ onset: TimeInterval, _ dur: TimeInterval, _ conf: Double = 0.9) -> DetectedNote {
        DetectedNote(midiNote: midi, onsetTime: onset, duration: dur, confidence: conf)
    }
    // pitch classes: C=0 D=2 E=4 G=7 A=9.  midi: C4=60 D3=50 E4=64 G3=55 A3=57
    private let D3 = 50, G3 = 55, A3 = 57, C4 = 60, E4 = 64, G4 = 67

    // MARK: - The bug: a D-then-G drone must not read as a confident G

    func testDthenGDroneIsNotConfidentG() {
        // Chris's intro: two bars droning D, then two bars droning G, opening on D. The histogram
        // can't tell D (I) from G (IV) — they're a perfect fourth apart. The opening establishes D
        // as home; the closing on G conflicts, so the answer is "D, but unsure", never a confident G.
        let notes = [note(D3, 0.0, 1.0), note(D3, 1.0, 1.0), note(G3, 2.0, 1.0), note(G3, 3.0, 1.0)]
        let result = MelodyKeyInference.infer(from: notes, maxCandidates: 2)
        XCTAssertGreaterThan(result.count, 0)
        XCTAssertEqual(result[0].key.root, .D, "the opening note D is home, not the closing G")
        XCTAssertNotEqual(result[0].key.root, .G, "must never confidently call the IV the tonic")
        // Open/close disagree on a fourth pair → low confidence, so a consumer's key gate goes quiet.
        XCTAssertLessThanOrEqual(result[0].score, MelodyKeyInference.nearTieScoreCeiling)
        // G is offered as the (fourth-related) alternative, so the user can pick it.
        XCTAssertTrue(result.contains { $0.key.root == .G }, "G stays available as the alternative")
    }

    func testGthenDDroneMirrorsToG() {
        // The mirror: open on G, then D. Proves the engine follows the actual opening, not a fixed
        // preference for D / the lower note.
        let notes = [note(G3, 0.0, 1.0), note(G3, 1.0, 1.0), note(D3, 2.0, 1.0), note(D3, 3.0, 1.0)]
        let result = MelodyKeyInference.infer(from: notes, maxCandidates: 2)
        XCTAssertEqual(result[0].key.root, .G, "opening on G makes G home")
    }

    // MARK: - Interval direction: fifth vs fourth both resolve to the opening

    func testDthenAFifthResolvesToOpening() {
        // D and A are a perfect FIFTH apart (the I-vs-V ambiguity), distinct from the fourth case.
        // Opening on D → D, balanced content so it's a genuine near-tie.
        let notes = [note(D3, 0.0, 1.0), note(A3, 1.0, 1.0), note(D3, 2.0, 1.0), note(A3, 3.0, 1.0)]
        let result = MelodyKeyInference.infer(from: notes, maxCandidates: 2)
        XCTAssertEqual(result[0].key.root, .D)
    }

    // MARK: - Guards: the opening/closing cue must NOT override a clear histogram winner

    func testOpensOnDominantStillReadsTheClearKey() {
        // A clear C-major triad melody that merely OPENS on G (the dominant). C major is the decisive
        // histogram winner, so G is not even a contender — opening-on-V must not flip the tonic.
        let notes = [
            note(G4, 0.0, 0.1),                 // brief pickup on the dominant
            note(C4, 0.1, 0.8), note(E4, 0.9, 0.8), note(G4, 1.7, 0.8),
            note(C4, 2.5, 0.8), note(E4, 3.3, 0.8),
        ]
        let result = MelodyKeyInference.infer(from: notes)
        XCTAssertEqual(result[0].key.root, .C)
        XCTAssertEqual(result[0].key.mode, .major)
    }

    func testEndsOnDominantStillReadsTheClearKey() {
        // A clear C-major melody ending on G (a half cadence). Closing-on-the-dominant earns no tonic
        // bonus, and C major is the clear winner — the tonic must stay C.
        let notes = [
            note(C4, 0.0, 0.8), note(E4, 0.8, 0.8), note(G4, 1.6, 0.4),
            note(C4, 2.0, 0.8), note(E4, 2.8, 0.4), note(G4, 3.2, 0.6),  // ends on G
        ]
        let result = MelodyKeyInference.infer(from: notes)
        XCTAssertEqual(result[0].key.root, .C)
        XCTAssertEqual(result[0].key.mode, .major)
    }

    // MARK: - Determinism (new argmaxes must not depend on input order)

    func testDeterministicUnderShuffle() {
        let notes = [note(D3, 0.0, 1.0), note(D3, 1.0, 1.0), note(G3, 2.0, 1.0), note(G3, 3.0, 1.0),
                     note(A3, 1.5, 0.3), note(E4, 2.5, 0.3)]
        let a = MelodyKeyInference.infer(from: notes, maxCandidates: 3)
        let b = MelodyKeyInference.infer(from: notes.reversed(), maxCandidates: 3)
        XCTAssertEqual(a.map { $0.key }, b.map { $0.key }, "result must not depend on input note order")
        XCTAssertEqual(a.map { $0.score }, b.map { $0.score })
    }
}
