import Foundation

/// Internal key inference engine for ProgressionAnalyzer.
enum ProgressionAnalyzer_KeyInference {

    static func inferKey(from chords: [Chord]) -> MusicalKey? {
        guard chords.count >= 2 else { return nil }

        var scores: [MusicalKey: Double] = [:]

        for note in NoteName.allCases {
            for mode in [KeyMode.major, KeyMode.minor] {
                let key = MusicalKey(root: note, mode: mode)
                scores[key] = scoreKey(key, for: chords)
            }
        }

        let bestKey = scores.max(by: { $0.value < $1.value })?.key

        if let key = bestKey, scores[key]! > 0 {
            return key
        }

        return nil
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
