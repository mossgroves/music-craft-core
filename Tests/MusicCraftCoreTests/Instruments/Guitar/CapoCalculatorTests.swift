import XCTest
@testable import MusicCraftCore

final class CapoCalculatorTests: XCTestCase {
    func testSuggestionsForGMajor() {
        let targetKey = MusicalKey(root: .G, mode: .major)
        let suggestions = CapoCalculator.suggestions(targetKey: targetKey, maxCapoFret: 7)

        XCTAssertLessThanOrEqual(suggestions.count, 3)
        XCTAssertGreaterThan(suggestions.count, 0)

        // All suggestions should be major keys
        for suggestion in suggestions {
            XCTAssertEqual(suggestion.targetKey, targetKey)
            XCTAssertEqual(suggestion.sourceKey.mode, .major)
        }
    }

    func testSuggestionsForAMinor() {
        let targetKey = MusicalKey(root: .A, mode: .minor)
        let suggestions = CapoCalculator.suggestions(targetKey: targetKey, maxCapoFret: 7)

        XCTAssertGreaterThan(suggestions.count, 0)

        // All should be minor keys
        for suggestion in suggestions {
            XCTAssertEqual(suggestion.sourceKey.mode, .minor)
        }
    }

    func testSuggestionsRespectMaxCapoFret() {
        let targetKey = MusicalKey(root: .B, mode: .major)
        let suggestions = CapoCalculator.suggestions(targetKey: targetKey, maxCapoFret: 3)

        for suggestion in suggestions {
            XCTAssertLessThanOrEqual(suggestion.capoFret, 3)
        }
    }

    func testSuggestionsAreSortedByScore() {
        let targetKey = MusicalKey(root: .E, mode: .major)
        let suggestions = CapoCalculator.suggestions(targetKey: targetKey, maxCapoFret: 7)

        for i in 0..<suggestions.count - 1 {
            XCTAssertGreaterThanOrEqual(suggestions[i].score, suggestions[i + 1].score)
        }
    }

    func testMajorAndMinorSeparation() {
        // Major target should not return minor sources
        let majorKey = MusicalKey(root: .C, mode: .major)
        let majorSuggestions = CapoCalculator.suggestions(targetKey: majorKey, maxCapoFret: 7)

        for suggestion in majorSuggestions {
            XCTAssertEqual(suggestion.sourceKey.mode, .major)
        }

        // Minor target should not return major sources
        let minorKey = MusicalKey(root: .C, mode: .minor)
        let minorSuggestions = CapoCalculator.suggestions(targetKey: minorKey, maxCapoFret: 7)

        for suggestion in minorSuggestions {
            XCTAssertEqual(suggestion.sourceKey.mode, .minor)
        }
    }

    func testCapoSuggestionEquality() {
        let suggest1 = CapoSuggestion(
            sourceKey: MusicalKey(root: .C, mode: .major),
            capoFret: 5,
            targetKey: MusicalKey(root: .G, mode: .major),
            score: 10.0
        )
        let suggest2 = CapoSuggestion(
            sourceKey: MusicalKey(root: .C, mode: .major),
            capoFret: 5,
            targetKey: MusicalKey(root: .G, mode: .major),
            score: 10.0
        )
        XCTAssertEqual(suggest1, suggest2)
    }
}
