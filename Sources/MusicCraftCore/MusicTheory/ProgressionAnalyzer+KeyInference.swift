import Foundation

/// Internal key inference engine for ProgressionAnalyzer.
enum ProgressionAnalyzer_KeyInference {

    static func inferKey(from chords: [Chord]) -> MusicalKey? {
        guard chords.count >= 2 else { return nil }
        guard let best = rankedKeys(for: chords).first, best.score > 0 else { return nil }
        return best.key
    }

    /// Every key with its score, best first, in a TOTAL order: the same chords always rank the
    /// same way, in every process.
    ///
    /// WHY. Until 0.1.19 the winner was `scores.max(by:)` over a `[MusicalKey: Double]`, and Swift
    /// seeds Dictionary iteration per process, so an EXACT tie between two keys resolved by hash
    /// seed. The key then biases the second chord decode (`ChordSequenceDecoder.nonDiatonicPenalty`),
    /// so a tie flipped chords too: one of the 18 corpus takes flipped 36 of 38 segments between two
    /// runs of the same binary, and 22 of 360 GuitarSet excerpts changed key run to run (CHANGELOG
    /// 0.1.7, 0.1.16; the app's `docs/audits/public-corpus-2026-09-08.md`). Wherever there is no
    /// tie the winner is the one `max` found; only ties are decided differently, and now always the
    /// same way.
    ///
    /// The tie order, mirroring `MelodyKeyInference` (the opening is home, the closing corroborates,
    /// then the same stable order it uses):
    ///   1. score, higher first;
    ///   2. the key whose tonic is the OPENING chord's root;
    ///   3. the key whose tonic is the CLOSING chord's root;
    ///   4. lower root (C before C♯ ...);
    ///   5. major before minor.
    static func rankedKeys(for chords: [Chord]) -> [(key: MusicalKey, score: Double)] {
        var ranked: [(key: MusicalKey, score: Double)] = []
        ranked.reserveCapacity(24)
        for note in NoteName.allCases {
            for mode in [KeyMode.major, KeyMode.minor] {
                let key = MusicalKey(root: note, mode: mode)
                ranked.append((key: key, score: scoreKey(key, for: chords)))
            }
        }
        let opening = chords.first?.root
        let closing = chords.last?.root
        ranked.sort { a, b in
            if a.score != b.score { return a.score > b.score }
            let aOpens = a.key.root == opening, bOpens = b.key.root == opening
            if aOpens != bOpens { return aOpens }
            let aCloses = a.key.root == closing, bCloses = b.key.root == closing
            if aCloses != bCloses { return aCloses }
            if a.key.root.rawValue != b.key.root.rawValue { return a.key.root.rawValue < b.key.root.rawValue }
            return a.key.mode == .major && b.key.mode == .minor
        }
        return ranked
    }

    private static func scoreKey(_ key: MusicalKey, for chords: [Chord]) -> Double {
        guard !chords.isEmpty else { return 0 }

        var score: Double = 0
        let diatonicQualities = key.diatonicQualities
        let scaleIntervals = key.scaleIntervals

        for (index, chord) in chords.enumerated() {
            let semitones = ((chord.root.rawValue - key.root.rawValue) + 12) % 12

            if let degreeIndex = scaleIntervals.firstIndex(of: semitones) {
                let diatonicQuality = diatonicQualities[degreeIndex]
                let degree = degreeIndex + 1

                let isQualityMatch = qualityMatches(chord.quality, diatonic: diatonicQuality)
                let isTonicChord = chord.root == key.root

                if index == 0 {
                    if isQualityMatch {
                        score += 3.0
                    } else {
                        score += 1.5
                    }
                }

                if isQualityMatch {
                    score += 0.5
                }

                if isTonicChord {
                    score += 1.0
                }

                if index > 0 {
                    let previousChord = chords[index - 1]
                    let prevSemitones = ((previousChord.root.rawValue - key.root.rawValue) + 12) % 12

                    if let prevDegreeIndex = scaleIntervals.firstIndex(of: prevSemitones) {
                        let prevDegree = prevDegreeIndex + 1

                        if prevDegree == 5 && degree == 1 {
                            score += 2.0
                        } else if prevDegree == 4 && degree == 1 {
                            score += 1.0
                        }
                    }
                }

                if key.mode == .minor && semitones == 10 && chord.quality == .major {
                    score += 1.5
                }
            }
        }

        return score
    }

    private static func qualityMatches(_ chordQuality: ChordQuality, diatonic: ChordQuality) -> Bool {
        switch (chordQuality, diatonic) {
        case (.major, .major), (.minor, .minor), (.diminished, .diminished), (.augmented, .augmented):
            return true
        case (.dominant7, .major), (.major7, .major), (.minor7, .minor), (.halfDiminished7, .diminished), (.diminished7, .diminished):
            return true
        default:
            return false
        }
    }
}
