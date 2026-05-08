import XCTest
@testable import MusicCraftCore

final class VoicingScoreTests: XCTestCase {
    func testOpenAmScoresHigherOpennessThanBarreAm() {
        let chord = Chord(root: .A, quality: .minor)

        // Open A minor: 0 0 2 2 1 0
        let openPos = VoicingPosition(
            frets: [0, 0, 2, 2, 1, 0],
            fingers: [0, 0, 1, 2, 1, 0],
            baseFret: 1
        )
        let openVoicing = GuitarVoicing(chord: chord, tuning: GuitarTuning.standard, position: openPos)
        let openScore = MusicCraftCore.score(openVoicing)

        // Barre A minor at fret 5: 5 7 7 6 5 5
        let barrePos = VoicingPosition(
            frets: [5, 7, 7, 6, 5, 5],
            fingers: [1, 3, 4, 2, 1, 1],
            baseFret: 5,
            barres: [5]
        )
        let barreVoicing = GuitarVoicing(chord: chord, tuning: GuitarTuning.standard, position: barrePos)
        let barreScore = MusicCraftCore.score(barreVoicing)

        XCTAssertGreaterThan(openScore.openness, barreScore.openness)
    }

    func testPositionScore() {
        let chord = Chord(root: .C, quality: .major)

        let openPos = VoicingPosition(
            frets: [0, 3, 2, 0, 1, 0],
            fingers: [0, 3, 2, 0, 1, 0],
            baseFret: 1
        )
        let openVoicing = GuitarVoicing(chord: chord, tuning: GuitarTuning.standard, position: openPos)
        let openScore = MusicCraftCore.score(openVoicing)

        let higherPos = VoicingPosition(
            frets: [3, 3, 2, 0, 1, 0],
            fingers: [3, 3, 2, 0, 1, 0],
            baseFret: 3
        )
        let higherVoicing = GuitarVoicing(chord: chord, tuning: GuitarTuning.standard, position: higherPos)
        let higherScore = MusicCraftCore.score(higherVoicing)

        XCTAssertGreaterThan(openScore.positionScore, higherScore.positionScore)
    }

    func testDefaultCriteriaWeightsNormalized() {
        let criteria = VoicingScoringCriteria.default
        let sum = criteria.weightDifficulty + criteria.weightOpenness + criteria.weightPosition + criteria.weightSpan
        XCTAssertEqual(sum, 1.0, accuracy: 0.001)
    }

    func testCustomCriteria() {
        // Valid: weights sum to 1.0
        let validCriteria = VoicingScoringCriteria(
            weightDifficulty: 0.4,
            weightOpenness: 0.3,
            weightPosition: 0.2,
            weightSpan: 0.1
        )
        let sum = validCriteria.weightDifficulty + validCriteria.weightOpenness + validCriteria.weightPosition + validCriteria.weightSpan
        XCTAssertEqual(sum, 1.0, accuracy: 0.001)
    }

    func testCustomCriteriaProduceDifferentScores() {
        let chord = Chord(root: .C, quality: .major)
        let pos = VoicingPosition(
            frets: [0, 3, 2, 0, 1, 0],
            fingers: [0, 3, 2, 0, 1, 0],
            baseFret: 1
        )
        let voicing = GuitarVoicing(chord: chord, tuning: GuitarTuning.standard, position: pos)

        let defaultScore = MusicCraftCore.score(voicing, criteria: .default)

        let customCriteria = VoicingScoringCriteria(
            weightDifficulty: 0.1,
            weightOpenness: 0.7,
            weightPosition: 0.1,
            weightSpan: 0.1
        )
        let customScore = MusicCraftCore.score(voicing, criteria: customCriteria)

        // Different criteria should produce different scores
        XCTAssertNotEqual(defaultScore.totalScore, customScore.totalScore)
        // Custom criteria weight openness 0.7 vs default 0.3, so custom should score higher
        XCTAssertGreaterThan(customScore.totalScore, defaultScore.totalScore)
    }

    func testScoreComponentsInRange() {
        let chord = Chord(root: .A, quality: .minor)
        let pos = VoicingPosition(
            frets: [0, 0, 2, 2, 1, 0],
            fingers: [0, 0, 1, 2, 1, 0],
            baseFret: 1
        )
        let voicing = GuitarVoicing(chord: chord, tuning: GuitarTuning.standard, position: pos)
        let voicingScore = MusicCraftCore.score(voicing)

        XCTAssertGreaterThanOrEqual(voicingScore.fingeringDifficulty, 0.0)
        XCTAssertLessThanOrEqual(voicingScore.fingeringDifficulty, 1.0)

        XCTAssertGreaterThanOrEqual(voicingScore.openness, 0.0)
        XCTAssertLessThanOrEqual(voicingScore.openness, 1.0)

        XCTAssertGreaterThanOrEqual(voicingScore.positionScore, 0.0)
        XCTAssertLessThanOrEqual(voicingScore.positionScore, 1.0)

        XCTAssertGreaterThanOrEqual(voicingScore.spanScore, 0.0)
        XCTAssertLessThanOrEqual(voicingScore.spanScore, 1.0)

        XCTAssertGreaterThanOrEqual(voicingScore.totalScore, 0.0)
        XCTAssertLessThanOrEqual(voicingScore.totalScore, 1.0)
    }
}
