import XCTest
@testable import MusicCraftCore

final class RomanNumeralTests: XCTestCase {

    // MARK: - Diatonic Chords in C Major

    func testCMajorI() {
        let key = MusicalKey(root: .C, mode: .major)
        let chord = Chord(root: .C, quality: .major)
        let roman = RomanNumeral(chord: chord, in: key)
        XCTAssertNotNil(roman)
        XCTAssertEqual(roman?.degree, .one)
        XCTAssertEqual(roman?.accidental, .natural)
        XCTAssertEqual(roman?.quality, .major)
        XCTAssertEqual(roman?.displayString, "I")
    }

    func testCMajorII() {
        let key = MusicalKey(root: .C, mode: .major)
        let chord = Chord(root: .D, quality: .minor)
        let roman = RomanNumeral(chord: chord, in: key)
        XCTAssertNotNil(roman)
        XCTAssertEqual(roman?.degree, .two)
        XCTAssertEqual(roman?.quality, .minor)
        XCTAssertEqual(roman?.displayString, "ii")
    }

    func testCMajorIII() {
        let key = MusicalKey(root: .C, mode: .major)
        let chord = Chord(root: .E, quality: .minor)
        let roman = RomanNumeral(chord: chord, in: key)
        XCTAssertNotNil(roman)
        XCTAssertEqual(roman?.degree, .three)
        XCTAssertEqual(roman?.quality, .minor)
        XCTAssertEqual(roman?.displayString, "iii")
    }

    func testCMajorIV() {
        let key = MusicalKey(root: .C, mode: .major)
        let chord = Chord(root: .F, quality: .major)
        let roman = RomanNumeral(chord: chord, in: key)
        XCTAssertNotNil(roman)
        XCTAssertEqual(roman?.degree, .four)
        XCTAssertEqual(roman?.quality, .major)
        XCTAssertEqual(roman?.displayString, "IV")
    }

    func testCMajorV() {
        let key = MusicalKey(root: .C, mode: .major)
        let chord = Chord(root: .G, quality: .major)
        let roman = RomanNumeral(chord: chord, in: key)
        XCTAssertNotNil(roman)
        XCTAssertEqual(roman?.degree, .five)
        XCTAssertEqual(roman?.quality, .major)
        XCTAssertEqual(roman?.displayString, "V")
    }

    func testCMajorVI() {
        let key = MusicalKey(root: .C, mode: .major)
        let chord = Chord(root: .A, quality: .minor)
        let roman = RomanNumeral(chord: chord, in: key)
        XCTAssertNotNil(roman)
        XCTAssertEqual(roman?.degree, .six)
        XCTAssertEqual(roman?.quality, .minor)
        XCTAssertEqual(roman?.displayString, "vi")
    }

    func testCMajorVII() {
        let key = MusicalKey(root: .C, mode: .major)
        let chord = Chord(root: .B, quality: .diminished)
        let roman = RomanNumeral(chord: chord, in: key)
        XCTAssertNotNil(roman)
        XCTAssertEqual(roman?.degree, .seven)
        XCTAssertEqual(roman?.quality, .diminished)
        XCTAssertEqual(roman?.displayString, "vii°")
    }

    // MARK: - Diatonic Chords in A Minor

    func testAMinorI() {
        let key = MusicalKey(root: .A, mode: .minor)
        let chord = Chord(root: .A, quality: .minor)
        let roman = RomanNumeral(chord: chord, in: key)
        XCTAssertNotNil(roman)
        XCTAssertEqual(roman?.degree, .one)
        XCTAssertEqual(roman?.quality, .minor)
        XCTAssertEqual(roman?.displayString, "i")
    }

    func testAMinorII() {
        let key = MusicalKey(root: .A, mode: .minor)
        let chord = Chord(root: .B, quality: .diminished)
        let roman = RomanNumeral(chord: chord, in: key)
        XCTAssertNotNil(roman)
        XCTAssertEqual(roman?.degree, .two)
        XCTAssertEqual(roman?.quality, .diminished)
        XCTAssertEqual(roman?.displayString, "ii°")
    }

    func testAMinorIII() {
        let key = MusicalKey(root: .A, mode: .minor)
        let chord = Chord(root: .C, quality: .major)
        let roman = RomanNumeral(chord: chord, in: key)
        XCTAssertNotNil(roman)
        XCTAssertEqual(roman?.degree, .three)
        XCTAssertEqual(roman?.quality, .major)
        XCTAssertEqual(roman?.displayString, "III")
    }

    func testAMinorIV() {
        let key = MusicalKey(root: .A, mode: .minor)
        let chord = Chord(root: .D, quality: .minor)
        let roman = RomanNumeral(chord: chord, in: key)
        XCTAssertNotNil(roman)
        XCTAssertEqual(roman?.degree, .four)
        XCTAssertEqual(roman?.quality, .minor)
        XCTAssertEqual(roman?.displayString, "iv")
    }

    func testAMinorV() {
        let key = MusicalKey(root: .A, mode: .minor)
        let chord = Chord(root: .E, quality: .minor)
        let roman = RomanNumeral(chord: chord, in: key)
        XCTAssertNotNil(roman)
        XCTAssertEqual(roman?.degree, .five)
        XCTAssertEqual(roman?.quality, .minor)
        XCTAssertEqual(roman?.displayString, "v")
    }

    func testAMinorVI() {
        let key = MusicalKey(root: .A, mode: .minor)
        let chord = Chord(root: .F, quality: .major)
        let roman = RomanNumeral(chord: chord, in: key)
        XCTAssertNotNil(roman)
        XCTAssertEqual(roman?.degree, .six)
        XCTAssertEqual(roman?.quality, .major)
        XCTAssertEqual(roman?.displayString, "VI")
    }

    func testAMinorVII() {
        let key = MusicalKey(root: .A, mode: .minor)
        let chord = Chord(root: .G, quality: .major)
        let roman = RomanNumeral(chord: chord, in: key)
        XCTAssertNotNil(roman)
        XCTAssertEqual(roman?.degree, .seven)
        XCTAssertEqual(roman?.quality, .major)
        XCTAssertEqual(roman?.displayString, "VII")
    }

    // MARK: - Non-diatonic Chords

    func testNonDiatonicFsInCMajor() {
        let key = MusicalKey(root: .C, mode: .major)
        let chord = Chord(root: .As, quality: .diminished)
        let roman = RomanNumeral(chord: chord, in: key)
        XCTAssertNil(roman)
    }

    func testNonDiatonicFsInAMinor() {
        let key = MusicalKey(root: .A, mode: .minor)
        let chord = Chord(root: .Fs, quality: .major)
        let roman = RomanNumeral(chord: chord, in: key)
        XCTAssertNil(roman)
    }

    // MARK: - Borrowed Chords (Major Key)

    func testNeapolitanDbInCMajor() {
        let key = MusicalKey(root: .C, mode: .major)
        let chord = Chord(root: .Cs, quality: .major)
        let roman = RomanNumeral(chord: chord, in: key)
        XCTAssertNotNil(roman)
        XCTAssertEqual(roman?.degree, .two)
        XCTAssertEqual(roman?.accidental, .flat)
        XCTAssertEqual(roman?.quality, .major)
        XCTAssertEqual(roman?.displayString, "♭II")
    }

    func testBorrowedBbInCMajor() {
        let key = MusicalKey(root: .C, mode: .major)
        let chord = Chord(root: .As, quality: .major)
        let roman = RomanNumeral(chord: chord, in: key)
        XCTAssertNotNil(roman)
        XCTAssertEqual(roman?.degree, .seven)
        XCTAssertEqual(roman?.accidental, .flat)
        XCTAssertEqual(roman?.quality, .major)
        XCTAssertEqual(roman?.displayString, "♭VII")
    }

    func testBorrowedEbInCMajor() {
        let key = MusicalKey(root: .C, mode: .major)
        let chord = Chord(root: .Ds, quality: .major)
        let roman = RomanNumeral(chord: chord, in: key)
        XCTAssertNotNil(roman)
        XCTAssertEqual(roman?.degree, .three)
        XCTAssertEqual(roman?.accidental, .flat)
        XCTAssertEqual(roman?.quality, .major)
        XCTAssertEqual(roman?.displayString, "♭III")
    }

    func testBorrowedAbInCMajor() {
        let key = MusicalKey(root: .C, mode: .major)
        let chord = Chord(root: .Gs, quality: .major)
        let roman = RomanNumeral(chord: chord, in: key)
        XCTAssertNotNil(roman)
        XCTAssertEqual(roman?.degree, .six)
        XCTAssertEqual(roman?.accidental, .flat)
        XCTAssertEqual(roman?.quality, .major)
        XCTAssertEqual(roman?.displayString, "♭VI")
    }

    func testSharpFsInCMajor() {
        let key = MusicalKey(root: .C, mode: .major)
        let chord = Chord(root: .Fs, quality: .major)
        let roman = RomanNumeral(chord: chord, in: key)
        XCTAssertNotNil(roman)
        XCTAssertEqual(roman?.degree, .four)
        XCTAssertEqual(roman?.accidental, .sharp)
        XCTAssertEqual(roman?.quality, .major)
        XCTAssertEqual(roman?.displayString, "♯IV")
    }

    // MARK: - Quality Suffixes

    func testQualitySuffixMajor() {
        let roman = RomanNumeral(degree: .five, accidental: .natural, quality: .major)
        XCTAssertEqual(roman.displayString, "V")
    }

    func testQualitySuffixMinor() {
        let roman = RomanNumeral(degree: .five, accidental: .natural, quality: .minor)
        XCTAssertEqual(roman.displayString, "v")
    }

    func testQualitySuffixDiminished() {
        let roman = RomanNumeral(degree: .five, accidental: .natural, quality: .diminished)
        XCTAssertEqual(roman.displayString, "v°")
    }

    func testQualitySuffixAugmented() {
        let roman = RomanNumeral(degree: .five, accidental: .natural, quality: .augmented)
        XCTAssertEqual(roman.displayString, "V+")
    }

    func testQualitySuffixDominant7() {
        let roman = RomanNumeral(degree: .five, accidental: .natural, quality: .dominant7)
        XCTAssertEqual(roman.displayString, "V7")
    }

    func testQualitySuffixMajor7() {
        let roman = RomanNumeral(degree: .five, accidental: .natural, quality: .major7)
        XCTAssertEqual(roman.displayString, "VΔ7")
    }

    func testQualitySuffixMinor7() {
        let roman = RomanNumeral(degree: .five, accidental: .natural, quality: .minor7)
        XCTAssertEqual(roman.displayString, "v7")
    }

    func testQualitySuffixHalfDiminished7() {
        let roman = RomanNumeral(degree: .five, accidental: .natural, quality: .halfDiminished7)
        XCTAssertEqual(roman.displayString, "vø7")
    }

    func testQualitySuffixDiminished7() {
        let roman = RomanNumeral(degree: .five, accidental: .natural, quality: .diminished7)
        XCTAssertEqual(roman.displayString, "v°7")
    }

    // MARK: - Equality and Hashability

    func testEquality() {
        let r1 = RomanNumeral(degree: .five, accidental: .natural, quality: .major)
        let r2 = RomanNumeral(degree: .five, accidental: .natural, quality: .major)
        XCTAssertEqual(r1, r2)
    }

    func testInequality() {
        let r1 = RomanNumeral(degree: .five, accidental: .natural, quality: .major)
        let r2 = RomanNumeral(degree: .five, accidental: .flat, quality: .major)
        XCTAssertNotEqual(r1, r2)
    }

    func testHashable() {
        let r1 = RomanNumeral(degree: .five, accidental: .natural, quality: .major)
        let r2 = RomanNumeral(degree: .five, accidental: .natural, quality: .major)
        var set = Set<RomanNumeral>()
        set.insert(r1)
        set.insert(r2)
        XCTAssertEqual(set.count, 1)
    }

    // MARK: - Sendable Compile Check

    func testSendableCompiles() {
        let roman = RomanNumeral(degree: .five, accidental: .natural, quality: .major)
        Task {
            let captured = roman
            _ = captured
        }
    }

    // MARK: - Fixture Test

    func testFixtureProgressionMatchesRomanNumerals() {
        let key = MusicalKey(root: .C, mode: .major)
        let chords = [
            Chord(root: .C, quality: .major),
            Chord(root: .G, quality: .major),
            Chord(root: .A, quality: .minor),
            Chord(root: .F, quality: .major)
        ]

        let numerals = chords.compactMap { RomanNumeral(chord: $0, in: key) }
        XCTAssertEqual(numerals.count, 4)

        XCTAssertEqual(numerals[0].degree, .one)
        XCTAssertEqual(numerals[0].quality, .major)
        XCTAssertEqual(numerals[1].degree, .five)
        XCTAssertEqual(numerals[1].quality, .major)
        XCTAssertEqual(numerals[2].degree, .six)
        XCTAssertEqual(numerals[2].quality, .minor)
        XCTAssertEqual(numerals[3].degree, .four)
        XCTAssertEqual(numerals[3].quality, .major)

        let dict: [Array<RomanNumeral>: String] = [numerals: "Pop Anthem"]
        XCTAssertEqual(dict[numerals], "Pop Anthem")
    }
}
