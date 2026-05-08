import Foundation

/// A scored guitar voicing with component scores and weighted total.
public struct VoicingScore: Equatable, Hashable, Sendable {
    /// Fingering difficulty: 0–1, lower = easier
    /// Computed as 1 - (uniqueFingersUsed/4 + barres_penalty + span_penalty)
    public let fingeringDifficulty: Double

    /// Openness: 0–1, higher = more open strings
    public let openness: Double

    /// Position score: 0–1, higher = lower on fretboard (near open position)
    public let positionScore: Double

    /// Span score: 0–1, higher = tighter fret span
    public let spanScore: Double

    /// Weighted total score: 0–1
    /// Computed as: w_fd*(1-fingeringDifficulty) + w_o*openness + w_p*positionScore + w_s*spanScore
    public let totalScore: Double

    public init(
        fingeringDifficulty: Double,
        openness: Double,
        positionScore: Double,
        spanScore: Double,
        totalScore: Double
    ) {
        self.fingeringDifficulty = fingeringDifficulty
        self.openness = openness
        self.positionScore = positionScore
        self.spanScore = spanScore
        self.totalScore = totalScore
    }
}

/// Composable scoring criteria for voicing selection.
///
/// Weights are normalized to sum to 1.0 ± 0.001. Default criteria favor
/// open-position accessibility for singer-songwriter use case.
public struct VoicingScoringCriteria: Equatable, Hashable, Sendable {
    /// Weight for fingering difficulty (lower difficulty = higher score)
    public let weightDifficulty: Double

    /// Weight for openness (more open strings = higher score)
    public let weightOpenness: Double

    /// Weight for position (lower position = higher score)
    public let weightPosition: Double

    /// Weight for span (tighter span = higher score)
    public let weightSpan: Double

    /// Default criteria: 0.4 difficulty, 0.3 openness, 0.2 position, 0.1 span
    /// Tuned for open-position-preferring acoustic singer-songwriter use case.
    public static let `default` = VoicingScoringCriteria(
        weightDifficulty: 0.4,
        weightOpenness: 0.3,
        weightPosition: 0.2,
        weightSpan: 0.1
    )

    public init(
        weightDifficulty: Double,
        weightOpenness: Double,
        weightPosition: Double,
        weightSpan: Double
    ) {
        // Validate weights sum to 1.0 ± 0.001
        let sum = weightDifficulty + weightOpenness + weightPosition + weightSpan
        precondition(abs(sum - 1.0) <= 0.001, "Weights must sum to 1.0 ± 0.001 (got \(sum))")

        self.weightDifficulty = weightDifficulty
        self.weightOpenness = weightOpenness
        self.weightPosition = weightPosition
        self.weightSpan = weightSpan
    }
}

/// Score a voicing using optional custom criteria.
public func score(_ voicing: GuitarVoicing, criteria: VoicingScoringCriteria = .default) -> VoicingScore {
    let position = voicing.position

    // Fingering difficulty
    let uniqueFingers = Set(position.fingers.filter { $0 > 0 }).count
    var difficulty = Double(uniqueFingers) / 4.0
    if position.barres != nil {
        difficulty += 0.2
    }
    let frettedFrets = position.frets.filter { $0 >= 0 }
    if let minFret = frettedFrets.min(), let maxFret = frettedFrets.max() {
        let fretSpan = maxFret - minFret
        if fretSpan > 4 {
            difficulty += 0.2
        }
    }
    let fingeringDifficulty = min(1.0, difficulty)

    // Openness: count open strings
    let openCount = position.frets.filter { $0 == 0 }.count
    let openness = Double(openCount) / 6.0

    // Position score: lower baseFret is better
    let positionScore = max(0.0, 1.0 - Double(position.baseFret) / 12.0)

    // Span score: tighter fret span is better
    let frettedFrets2 = position.frets.filter { $0 >= 0 }
    let spanScore: Double
    if let minFret = frettedFrets2.min(), let maxFret = frettedFrets2.max() {
        let fretSpan = Double(maxFret - minFret)
        spanScore = max(0.0, 1.0 - min(fretSpan / 4.0, 1.0))
    } else {
        spanScore = 1.0
    }

    // Total score
    let totalScore = (criteria.weightDifficulty * (1.0 - fingeringDifficulty) +
                      criteria.weightOpenness * openness +
                      criteria.weightPosition * positionScore +
                      criteria.weightSpan * spanScore)

    return VoicingScore(
        fingeringDifficulty: fingeringDifficulty,
        openness: openness,
        positionScore: positionScore,
        spanScore: spanScore,
        totalScore: totalScore
    )
}
