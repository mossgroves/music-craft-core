import XCTest
@testable import MusicCraftCore

/// The key a chord list infers is the same in every process (0.1.19).
///
/// WHY. Until 0.1.19 `inferKey` took `max` over a `[MusicalKey: Double]`; Swift seeds Dictionary
/// order per process, so an EXACT tie between two keys resolved by hash seed, and because the key
/// biases the second chord decode, a tie flipped chords as well as the key (one corpus take flipped
/// 36 of 38 segments between two runs; 22 of 360 GuitarSet excerpts changed key run to run). Ties
/// are not rare: 72 of the 576 two-chord sequences over major and minor triads tie at the top.
/// `rankedKeys` now sorts the 24 keys in a TOTAL order: score, then the key whose tonic is the
/// opening chord's root, then the closing chord's root, then the lower root, then major before
/// minor, the same cues and the same stable tail `MelodyKeyInference` uses.
final class ProgressionAnalyzerTieBreakTests: XCTestCase {

    private func chord(_ root: NoteName, _ quality: ChordQuality = .major) -> Chord {
        Chord(root: root, quality: quality)
    }

    private func top2(_ chords: [Chord]) -> (MusicalKey, MusicalKey, Double, Double) {
        let r = ProgressionAnalyzer_KeyInference.rankedKeys(for: chords)
        return (r[0].key, r[1].key, r[0].score, r[1].score)
    }

    /// C then Em ties three ways (C major, E minor, D minor, all 5.0). The take opens on C, so C
    /// major is home.
    func testATieGoesToTheKeyTheTakeOpensOn() {
        let (first, second, s1, s2) = top2([chord(.C), chord(.E, .minor)])
        XCTAssertEqual(s1, s2, "the case must be an exact tie or it tests nothing")
        XCTAssertEqual(first, MusicalKey(root: .C, mode: .major))
        XCTAssertEqual(second, MusicalKey(root: .E, mode: .minor), "the closing chord's key is next")
        XCTAssertEqual(ProgressionAnalyzer.inferKey(from: [chord(.C), chord(.E, .minor)]),
                       MusicalKey(root: .C, mode: .major))
    }

    /// C then Gm ties G major with D minor (5.5); neither tonic opens the take, G closes it.
    func testWhenNeitherKeyOpensTheTakeTheClosingChordDecides() {
        let (first, _, s1, s2) = top2([chord(.C), chord(.G, .minor)])
        XCTAssertEqual(s1, s2)
        XCTAssertEqual(first, MusicalKey(root: .G, mode: .major))
    }

    /// C, D, Bm ties D minor with E minor (6.0); no tonic opens or closes the take, so the lower
    /// root wins.
    func testWithNoStructuralCueTheLowerRootWins() {
        let (first, second, s1, s2) = top2([chord(.C), chord(.D), chord(.B, .minor)])
        XCTAssertEqual(s1, s2)
        XCTAssertEqual(first, MusicalKey(root: .D, mode: .minor))
        XCTAssertEqual(second, MusicalKey(root: .E, mode: .minor))
    }

    /// D then E scores C major and C minor alike (1.5 each, no chord touches C); with the same root,
    /// major ranks first.
    func testSameRootTiesRankMajorBeforeMinor() {
        let ranked = ProgressionAnalyzer_KeyInference.rankedKeys(for: [chord(.D), chord(.E)])
        let major = ranked.firstIndex { $0.key == MusicalKey(root: .C, mode: .major) }!
        let minor = ranked.firstIndex { $0.key == MusicalKey(root: .C, mode: .minor) }!
        XCTAssertEqual(ranked[major].score, ranked[minor].score)
        XCTAssertLessThan(major, minor)
    }

    /// Every two-chord sequence over the 24 major and minor triads: the winner is a top scorer, and
    /// among the top scorers it is the one the stated order names. Fresh `Chord` values (new ids)
    /// on every call, so the ranking cannot lean on identity.
    func testTheStatedOrderHoldsOnEveryTwoChordSequence() {
        var pool: [(NoteName, ChordQuality)] = []
        for r in NoteName.allCases { for q in [ChordQuality.major, .minor] { pool.append((r, q)) } }
        var ties = 0
        for a in pool { for b in pool {
            let chords = [chord(a.0, a.1), chord(b.0, b.1)]
            let ranked = ProgressionAnalyzer_KeyInference.rankedKeys(for: chords)
            XCTAssertEqual(ranked.count, 24)
            let best = ranked[0].score
            let contenders = ranked.filter { $0.score == best }.map(\.key)
            if contenders.count > 1 { ties += 1 }
            let expected = contenders.min { x, y in
                let xo = x.root == a.0, yo = y.root == a.0
                if xo != yo { return xo }
                let xc = x.root == b.0, yc = y.root == b.0
                if xc != yc { return xc }
                if x.root.rawValue != y.root.rawValue { return x.root.rawValue < y.root.rawValue }
                return x.mode == .major && y.mode == .minor
            }!
            XCTAssertEqual(ranked[0].key, expected, "\(a) \(b)")
            let again = ProgressionAnalyzer_KeyInference.rankedKeys(for: [chord(a.0, a.1), chord(b.0, b.1)])
            XCTAssertEqual(again.map(\.key), ranked.map(\.key), "\(a) \(b): a second call ranked differently")
        } }
        XCTAssertEqual(ties, 72, "the tie count is part of the record; a scoring change moves it on purpose")
    }

    /// A tie never changes what `inferKey` returns when there is no tie: the 24-key round trip and
    /// the cadence cases in ProgressionAnalyzerTests still hold, and a clear winner is the max.
    func testAClearWinnerIsStillTheMaximum() {
        let chords = [chord(.C), chord(.F), chord(.G), chord(.C)]
        let ranked = ProgressionAnalyzer_KeyInference.rankedKeys(for: chords)
        XCTAssertGreaterThan(ranked[0].score, ranked[1].score)
        XCTAssertEqual(ranked[0].key, MusicalKey(root: .C, mode: .major))
        XCTAssertEqual(ranked[0].score, ranked.map(\.score).max())
    }
}
