import Foundation

/// Minimum 7th degree chroma energy to accept or preserve a 7th chord.
/// Used in Pass 2 chroma-based matching, parsimony downgrade, and seed upgrades.
/// Raised from 0.18 to 0.30: open D sympathetic resonance produces false 7th
/// energy in the 0.19–0.25 range, while genuine intentional 7th chords show 0.35+.
/// See TECHNICAL-ARCHITECTURE.md § Parsimony.
public let kParsimony7thUpgradeThreshold: Double = 0.30

/// Deterministic interval-based chord detection from chroma vectors.
///
/// Fallback path for when the trained classifier has low confidence (< 0.55).
/// Reads peaks directly from the 12-element chroma, calculates pairwise intervals,
/// and matches against known chord formulas from music theory.
///
/// Handles:
/// - Triads: major, minor, dim, aug, sus2, sus4
/// - Seventh chords: dom7, maj7, min7, dim7, half-dim7
/// - Power chords: root + 5th (2 peaks only)
/// - Overtone disambiguation: prefers simpler chord with strongest bin as root
public final class IntervalDetector {

    // Relative timestamp for detection logging (seconds since session start).
    nonisolated(unsafe) public static var sessionStartTime: CFAbsoluteTime = 0
    private static var ts: String {
        let elapsed = CFAbsoluteTimeGetCurrent() - sessionStartTime
        return "[ts=\(String(format: "%.3f", elapsed))]"
    }

    public struct Peak {
        public let note: NoteName
        public let energy: Double
    }

    public struct Result {
        public let root: NoteName
        public let quality: ChordQuality
        public let confidence: Double
        public let peaks: [Peak]
    }

    /// Chord formulas ordered by priority (simplest/most common first).
    /// When two formulas score equally, the earlier one wins.
    private static let chordFormulas: [(quality: ChordQuality, intervals: Set<Int>)] = [
        // Triads (most common, preferred)
        (.major,           [0, 4, 7]),
        (.minor,           [0, 3, 7]),
        (.sus4,            [0, 5, 7]),
        (.sus2,            [0, 2, 7]),
        (.diminished,      [0, 3, 6]),
        (.augmented,       [0, 4, 8]),
        // Seventh chords
        (.dominant7,       [0, 4, 7, 10]),
        (.major7,          [0, 4, 7, 11]),
        (.minor7,          [0, 3, 7, 10]),
        (.diminished7,     [0, 3, 6, 9]),
        (.halfDiminished7, [0, 3, 6, 10]),
    ]

    /// Detect chord from a normalized 12-element chroma vector using interval analysis.
    /// Returns nil if fewer than 2 clear peaks or no chord formula matches.
    ///
    /// - Parameters:
    ///   - chroma: 12-element chroma vector (post-baseline-subtraction, normalized)
    ///   - rawChroma: Optional pre-subtraction chroma for minor 3rd protection
    public static func detect(chroma: [Double], rawChroma: [Double]? = nil) -> Result? {
        guard chroma.count >= 12 else { return nil }
        let peaks = extractPeaks(chroma: chroma)

        if peaks.count < 2 { return nil }

        if peaks.count == 2 {
            return detectPowerChord(peaks: peaks, chroma: chroma)
        }

        guard let raw = matchIntervals(peaks: peaks, chroma: chroma) else { return nil }

        guard let (filtRoot, filtQuality, filtConf) = applyPlausibilityFilter(
            root: raw.root, quality: raw.quality, confidence: raw.confidence, chroma: chroma
        ) else { return nil }

        let finalRoot = filtRoot
        var finalQuality = filtQuality
        let finalConf = filtConf

        // Minor 3rd protection
        if finalQuality == .major, let rawChroma = rawChroma {
            let rootBin = finalRoot.rawValue
            let minor3rdBin = (rootBin + 3) % 12
            let major3rdBin = (rootBin + 4) % 12
            let rawMinor3rd = rawChroma[minor3rdBin]
            let rawMajor3rd = rawChroma[major3rdBin]

            if rawMinor3rd > 0.15 && rawMinor3rd > rawMajor3rd * 0.40 {
                let postMinor3rd = chroma[minor3rdBin]
                let postMajor3rd = chroma[major3rdBin]
                if postMajor3rd < postMinor3rd * 3.0 || postMinor3rd < 0.05 {
                    finalQuality = .minor
                }
            }
        }

        if finalRoot != raw.root || finalQuality != raw.quality || finalConf != raw.confidence {
            return Result(root: finalRoot, quality: finalQuality, confidence: finalConf, peaks: raw.peaks)
        }
        return raw
    }

    // MARK: - Peak Extraction

    private static func extractPeaks(chroma: [Double]) -> [Peak] {
        guard chroma.count >= 12 else { return [] }
        let maxVal = chroma.max() ?? 0
        guard maxVal > 0 else { return [] }

        let threshold = maxVal * 0.40
        var peaks: [Peak] = []
        for i in 0..<12 {
            if chroma[i] >= threshold {
                guard let note = NoteName(rawValue: i) else { continue }
                peaks.append(Peak(note: note, energy: chroma[i]))
            }
        }

        peaks.sort { $0.energy > $1.energy }
        return Array(peaks.prefix(5))
    }

    // MARK: - Power Chord Detection

    private static func detectPowerChord(peaks: [Peak], chroma: [Double]) -> Result? {
        guard peaks.count >= 2, chroma.count >= 12 else { return nil }
        let sorted = peaks.sorted { $0.energy > $1.energy }
        let stronger = sorted[0]
        let weaker = sorted[1]

        let interval = (weaker.note.rawValue - stronger.note.rawValue + 12) % 12

        let root: NoteName
        if interval == 7 {
            root = stronger.note
        } else if interval == 5 {
            root = weaker.note
        } else {
            return nil
        }

        let rootBin = root.rawValue
        let minor3rdBin = (rootBin + 3) % 12
        let major3rdBin = (rootBin + 4) % 12
        let minor3rdEnergy = chroma[minor3rdBin]
        let major3rdEnergy = chroma[major3rdBin]

        let promotionThreshold = 0.08
        let minValid = minor3rdEnergy >= promotionThreshold
        let majValid = major3rdEnergy >= promotionThreshold

        if minValid && majValid {
            if major3rdEnergy > minor3rdEnergy {
                return Result(root: root, quality: .major, confidence: 0.75, peaks: sorted)
            } else {
                return Result(root: root, quality: .minor, confidence: 0.75, peaks: sorted)
            }
        } else if majValid && !minValid {
            return Result(root: root, quality: .major, confidence: 0.70, peaks: sorted)
        } else if minValid && !majValid {
            return Result(root: root, quality: .minor, confidence: 0.75, peaks: sorted)
        }

        return nil
    }

    // MARK: - Interval Matching

    private static func matchIntervals(peaks: [Peak], chroma: [Double]) -> Result? {
        guard !peaks.isEmpty, chroma.count >= 12 else { return nil }
        let detectedNotes = Set(peaks.map { $0.note.rawValue })

        struct Candidate {
            let root: NoteName
            let quality: ChordQuality
            var score: Double
            let formulaIndex: Int
        }

        var candidates: [Candidate] = []

        // Pass 1: Peak-based interval matching
        for peak in peaks {
            let rootVal = peak.note.rawValue
            let intervalSet = Set(detectedNotes.map { ($0 - rootVal + 12) % 12 })

            for (formulaIdx, formula) in chordFormulas.enumerated() {
                let score = matchScore(detected: intervalSet, formula: formula.intervals)
                if score > 0 {
                    candidates.append(Candidate(
                        root: peak.note,
                        quality: formula.quality,
                        score: score,
                        formulaIndex: formulaIdx
                    ))
                }
            }
        }

        // Pass 2: Chroma-based 7th chord matching with lower thresholds
        let seventhFormulas: [(quality: ChordQuality, third: Int, fifth: Int, seventh: Int, idx: Int)] = [
            (.dominant7, 4, 7, 10, 6),
            (.major7,    4, 7, 11, 7),
            (.minor7,    3, 7, 10, 8),
        ]
        for rootVal in 0..<12 {
            guard let rootNote = NoteName(rawValue: rootVal),
                  chroma[rootVal] >= 0.15 else { continue }

            for f in seventhFormulas {
                let thirdEnergy = chroma[(rootVal + f.third) % 12]
                let fifthEnergy = chroma[(rootVal + f.fifth) % 12]
                let seventhEnergy = chroma[(rootVal + f.seventh) % 12]

                guard thirdEnergy >= 0.25,
                      fifthEnergy >= 0.25,
                      seventhEnergy >= kParsimony7thUpgradeThreshold else { continue }

                let minTone = min(chroma[rootVal], thirdEnergy, fifthEnergy, seventhEnergy)
                let score = 1.30 - max(0, 0.25 - minTone) * 0.4

                if let existingIdx = candidates.firstIndex(where: { $0.root == rootNote && $0.quality == f.quality }) {
                    if score > candidates[existingIdx].score {
                        candidates[existingIdx].score = score
                    }
                    continue
                }
                candidates.append(Candidate(
                    root: rootNote, quality: f.quality, score: score, formulaIndex: f.idx
                ))
            }
        }

        guard !candidates.isEmpty else { return nil }

        // Dom7 vs Maj7 disambiguation
        for rootVal in 0..<12 {
            guard let rootNote = NoteName(rawValue: rootVal) else { continue }
            let dom7Idx = candidates.firstIndex(where: { $0.root == rootNote && $0.quality == .dominant7 })
            let maj7Idx = candidates.firstIndex(where: { $0.root == rootNote && $0.quality == .major7 })
            if let di = dom7Idx, let mi = maj7Idx {
                let dom7Energy = chroma[(rootVal + 10) % 12]
                let maj7Energy = chroma[(rootVal + 11) % 12]
                if dom7Energy >= 0.15 || dom7Energy >= maj7Energy {
                    candidates[di].score *= 1.10
                    candidates[mi].score *= 0.85
                }
            }
        }

        // Root priority weighting
        for i in candidates.indices {
            let rootEnergy = chroma[candidates[i].root.rawValue]
            candidates[i].score *= (1.0 + 0.3 * min(rootEnergy, 1.0))
        }

        // Sort
        let strongestNote = peaks[0].note
        candidates.sort { a, b in
            if abs(a.score - b.score) > 0.01 { return a.score > b.score }
            if a.formulaIndex != b.formulaIndex { return a.formulaIndex < b.formulaIndex }
            if a.root == strongestNote && b.root != strongestNote { return true }
            if b.root == strongestNote && a.root != strongestNote { return false }
            return false
        }

        let best = candidates[0]

        // Overtone heuristic
        if best.root != strongestNote {
            if let simpler = candidates.first(where: {
                $0.root == strongestNote && $0.quality.intervals.count <= 3
                && $0.quality != .diminished && $0.quality != .augmented
            }) {
                if simpler.score >= best.score * 0.85 {
                    let conf = confidenceForScore(simpler.score)
                    return Result(
                        root: simpler.root,
                        quality: simpler.quality,
                        confidence: conf,
                        peaks: peaks
                    )
                }
            }
        }

        // Adjacent semitone disambiguation
        let (disambRoot, disambQuality) = disambiguateMinorMajor(
            root: best.root, quality: best.quality, chroma: chroma
        )

        // Parsimony filter for 7th chords
        let (filteredRoot, filteredQuality) = filterOvertone7th(
            root: disambRoot, quality: disambQuality, chroma: chroma
        )

        let conf = confidenceForScore(best.score)
        return Result(
            root: filteredRoot,
            quality: filteredQuality,
            confidence: conf,
            peaks: peaks
        )
    }

    private static func disambiguateMinorMajor(
        root: NoteName, quality: ChordQuality, chroma: [Double]
    ) -> (NoteName, ChordQuality) {
        guard chroma.count >= 12 else { return (root, quality) }
        let majorQuality: ChordQuality
        switch quality {
        case .minor:  majorQuality = .major
        case .minor7: majorQuality = .dominant7
        default: return (root, quality)
        }

        let rootBin = root.rawValue
        let minor3rdBin = (rootBin + 3) % 12
        let major3rdBin = (rootBin + 4) % 12

        let minor3rdEnergy = chroma[minor3rdBin]
        let major3rdEnergy = chroma[major3rdBin]

        guard major3rdEnergy > 0.15 else { return (root, quality) }

        if minor3rdEnergy < 2.0 * major3rdEnergy {
            return (root, majorQuality)
        }

        return (root, quality)
    }

    private static func filterOvertone7th(
        root: NoteName, quality: ChordQuality, chroma: [Double]
    ) -> (NoteName, ChordQuality) {
        guard chroma.count >= 12 else { return (root, quality) }
        let seventhInterval: Int
        let triadQuality: ChordQuality

        switch quality {
        case .dominant7:
            seventhInterval = 10
            triadQuality = .major
        case .major7:
            seventhInterval = 11
            triadQuality = .major
        case .minor7:
            seventhInterval = 10
            triadQuality = .minor
        default:
            return (root, quality)
        }

        let rootBin = root.rawValue
        let seventhBin = (rootBin + seventhInterval) % 12
        let seventhEnergy = chroma[seventhBin]

        if seventhEnergy < kParsimony7thUpgradeThreshold {
            return (root, triadQuality)
        }

        return (root, quality)
    }

    private static func matchScore(detected: Set<Int>, formula: Set<Int>) -> Double {
        let matched = formula.intersection(detected).count
        let missing = formula.count - matched
        let extra = detected.subtracting(formula).count

        guard matched >= 2 else { return 0 }

        guard missing <= 1 else { return 0 }

        if missing == 0 {
            if extra == 0 { return 1.0 }
            if extra == 1 { return 0.8 }
            return 0.6
        } else {
            if extra == 0 { return 0.7 }
            return max(0.5, 0.7 - Double(extra) * 0.1)
        }
    }

    private static func confidenceForScore(_ score: Double) -> Double {
        return min(0.85, 0.55 + score * 0.30)
    }

    // MARK: - Plausibility Filter

    private static func applyPlausibilityFilter(
        root: NoteName, quality: ChordQuality, confidence: Double, chroma: [Double]
    ) -> (NoteName, ChordQuality, Double)? {
        guard chroma.count >= 12 else { return nil }
        let rootBin = root.rawValue

        let isAccidentalRoot = [1, 3, 6, 8, 10].contains(rootBin)

        let isSimpleChord = quality == .major || quality == .minor || quality == .power
        if isSimpleChord { return (root, quality, confidence) }

        let definingNoteThreshold = 0.40
        switch quality {
        case .augmented:
            let sharpFifthBin = (rootBin + 8) % 12
            if chroma[sharpFifthBin] < definingNoteThreshold {
                return (root, .major, confidence * 0.90)
            }
        case .diminished:
            let flatFifthBin = (rootBin + 6) % 12
            if chroma[flatFifthBin] < definingNoteThreshold {
                return (root, .minor, confidence * 0.90)
            }
        case .sus2:
            let secondBin = (rootBin + 2) % 12
            if chroma[secondBin] < definingNoteThreshold {
                return (root, .major, confidence * 0.90)
            }
        case .sus4:
            let fourthBin = (rootBin + 5) % 12
            if chroma[fourthBin] < definingNoteThreshold {
                return (root, .major, confidence * 0.90)
            }
        default:
            break
        }

        if isAccidentalRoot && confidence < 0.80 {
            return nil
        }

        if confidence < 0.70 {
            switch quality {
            case .dominant7, .major7:
                return (root, .major, confidence)
            case .minor7:
                return (root, .minor, confidence)
            case .halfDiminished7:
                return (root, .minor, confidence)
            case .diminished7:
                return (root, .diminished, confidence)
            default:
                return nil
            }
        }

        return (root, quality, confidence)
    }
}
