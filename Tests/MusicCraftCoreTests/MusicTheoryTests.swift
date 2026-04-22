import XCTest
@testable import MusicCraftCore

final class MusicTheoryTests: XCTestCase {

    // MARK: - Chord Parsing

    func testChordParsingRoundTrips() {
        let testCases: [(input: String, expectedDisplay: String, root: NoteName)] = [
            ("C", "C", .C),
            ("Cm", "Cm", .C),
            ("Cdim", "C°", .C),
            ("Caug", "C+", .C),
            ("Csus2", "Csus2", .C),
            ("Csus4", "Csus4", .C),
            ("C7", "C7", .C),
            ("Cmaj7", "Cmaj7", .C),
            ("Cm7", "Cm7", .C),
            ("Cm(maj7)", "Cm(maj7)", .C),
            ("Cdim7", "C°7", .C),
            ("Cm7b5", "Cø7", .C),
            ("Cadd9", "Cadd9", .C),
        ]

        for (input, expectedDisplay, expectedRoot) in testCases {
            guard let chord = Chord(parsing: input) else {
                XCTFail("Failed to parse chord: \(input)")
                continue
            }
            XCTAssertEqual(chord.displayName, expectedDisplay, "Chord \(input) display name mismatch")
            XCTAssertEqual(chord.root, expectedRoot)
        }
    }

    func testChordParsingWithUnicodeSymbols() {
        let testCases = [
            ("F♯m", NoteName.Fs, ChordQuality.minor),
            ("B♭", NoteName.As, ChordQuality.major),
            ("C♯7", NoteName.Cs, ChordQuality.dominant7),
        ]

        for (input, expectedRoot, expectedQuality) in testCases {
            guard let chord = Chord(parsing: input) else {
                XCTFail("Failed to parse chord: \(input)")
                continue
            }
            XCTAssertEqual(chord.root, expectedRoot)
            XCTAssertEqual(chord.quality, expectedQuality)
        }
    }

    func testChordParsingWithAsciiSymbols() {
        let testCases = [
            ("F#m", NoteName.Fs, ChordQuality.minor),
            ("Bbdim", NoteName.As, ChordQuality.diminished),
            ("C#dim7", NoteName.Cs, ChordQuality.diminished7),
        ]

        for (input, expectedRoot, expectedQuality) in testCases {
            guard let chord = Chord(parsing: input) else {
                XCTFail("Failed to parse chord: \(input)")
                continue
            }
            XCTAssertEqual(chord.root, expectedRoot)
            XCTAssertEqual(chord.quality, expectedQuality)
        }
    }

    func testChordParsingInvalidInput() {
        XCTAssertNil(Chord(parsing: ""))
        XCTAssertNil(Chord(parsing: "xyz"))
        XCTAssertNil(Chord(parsing: "1"))
    }

    // MARK: - NoteName Enharmonic Equivalence

    func testNoteNameDisplayAndFlatNames() {
        XCTAssertEqual(NoteName.Cs.displayName, "C♯")
        XCTAssertEqual(NoteName.Cs.flatName, "D♭")

        XCTAssertEqual(NoteName.Ds.displayName, "D♯")
        XCTAssertEqual(NoteName.Ds.flatName, "E♭")

        XCTAssertEqual(NoteName.Fs.displayName, "F♯")
        XCTAssertEqual(NoteName.Fs.flatName, "G♭")

        XCTAssertEqual(NoteName.As.displayName, "A♯")
        XCTAssertEqual(NoteName.As.flatName, "B♭")
    }

    // MARK: - DiatonicChordGenerator

    func testDiatonicChordsInCMajor() {
        let key = MusicalKey(root: .C, mode: .major)
        let chords = DiatonicChordGenerator.generate(for: key)

        XCTAssertEqual(chords.count, 7)
        XCTAssertEqual(chords[0].degree, 1)
        XCTAssertEqual(chords[0].romanNumeral, "I")
        XCTAssertEqual(chords[0].quality, .major)
        XCTAssertEqual(chords[0].root.displayString, "C")

        XCTAssertEqual(chords[1].degree, 2)
        XCTAssertEqual(chords[1].romanNumeral, "ii")
        XCTAssertEqual(chords[1].quality, .minor)
        XCTAssertEqual(chords[1].root.displayString, "D")

        XCTAssertEqual(chords[4].degree, 5)
        XCTAssertEqual(chords[4].romanNumeral, "V")
        XCTAssertEqual(chords[4].quality, .major)
        XCTAssertEqual(chords[4].root.displayString, "G")
    }

    func testDiatonicChordsInAMinor() {
        let key = MusicalKey(root: .A, mode: .minor)
        let chords = DiatonicChordGenerator.generate(for: key)

        XCTAssertEqual(chords.count, 7)
        XCTAssertEqual(chords[0].degree, 1)
        XCTAssertEqual(chords[0].romanNumeral, "i")
        XCTAssertEqual(chords[0].quality, .minor)
        XCTAssertEqual(chords[0].root.displayString, "A")
    }

    func testDiatonicChordsInFSharpMajor() {
        let key = MusicalKey(root: .Fs, mode: .major)
        let chords = DiatonicChordGenerator.generate(for: key)

        XCTAssertEqual(chords.count, 7)
        // F# major has 6 sharps, so root should be F#
        XCTAssertEqual(chords[0].root.displayString, "F♯")
        XCTAssertEqual(chords[0].quality, .major)
        // Check that the diatonic chords spell correctly
        let degrees = chords.map(\.degree)
        XCTAssertEqual(degrees, [1, 2, 3, 4, 5, 6, 7])
    }

    func testDiatonicChordsInBbMajor() {
        let key = MusicalKey(root: .As, mode: .major)
        let chords = DiatonicChordGenerator.generate(for: key)

        XCTAssertEqual(chords.count, 7)
        // Bb major has 2 flats, so root should be Bb
        XCTAssertEqual(chords[0].root.displayString, "B♭")
        XCTAssertEqual(chords[0].quality, .major)
    }

    func testDiatonicChordsInEMinor() {
        let key = MusicalKey(root: .E, mode: .minor)
        let chords = DiatonicChordGenerator.generate(for: key)

        XCTAssertEqual(chords.count, 7)
        XCTAssertEqual(chords[0].degree, 1)
        XCTAssertEqual(chords[0].romanNumeral, "i")
        XCTAssertEqual(chords[0].quality, .minor)
        XCTAssertEqual(chords[0].root.displayString, "E")
    }

    // MARK: - Transposer

    func testTransposerCUpPerfectFifth() {
        let g = Transposer.chordName("V", rootSemitone: 0) // C=0, V = G
        XCTAssertEqual(g, "G")
    }

    func testTransposerFSharpMinorDownMinorThird() {
        // From F#/Gb (6), down a minor third = Ds/Eb (3)
        // Transposer uses fixed spelling from noteNames array
        let fsMajorRoot = NoteName.Fs.rawValue // 6
        let dsRoot = (fsMajorRoot - 3 + 12) % 12 // 3
        let dsChord = Transposer.chordName("i", rootSemitone: dsRoot) // minor chord
        // Transposer.noteNames[3] = "E♭", so the result is "E♭m"
        XCTAssertEqual(dsChord, "E♭m")
    }

    func testTransposerProgressionInDMajor() {
        let d = NoteName.D.rawValue // 2
        let progression = ["I", "IV", "V"]
        let transposed = Transposer.transposeProgression(progression, rootSemitone: d)
        XCTAssertEqual(transposed, ["D", "G", "A"])
    }

    // MARK: - MusicalKey

    func testMusicalKeyConstruction() {
        let cMajor = MusicalKey(root: .C, mode: .major)
        XCTAssertEqual(cMajor.displayName, "C major")

        let aMinor = MusicalKey(root: .A, mode: .minor)
        XCTAssertEqual(aMinor.displayName, "A minor")
    }

    func testMusicalKeyEquality() {
        let k1 = MusicalKey(root: .C, mode: .major)
        let k2 = MusicalKey(root: .C, mode: .major)
        let k3 = MusicalKey(root: .D, mode: .major)

        XCTAssertEqual(k1, k2)
        XCTAssertNotEqual(k1, k3)
    }

    func testMusicalKeyScaleIntervals() {
        let cMajor = MusicalKey(root: .C, mode: .major)
        XCTAssertEqual(cMajor.scaleIntervals, [0, 2, 4, 5, 7, 9, 11])

        let cMinor = MusicalKey(root: .C, mode: .minor)
        XCTAssertEqual(cMinor.scaleIntervals, [0, 2, 3, 5, 7, 8, 10])
    }

    func testMusicalKeyDiatonicQualities() {
        let cMajor = MusicalKey(root: .C, mode: .major)
        XCTAssertEqual(cMajor.diatonicQualities, [.major, .minor, .minor, .major, .major, .minor, .diminished])

        let cMinor = MusicalKey(root: .C, mode: .minor)
        XCTAssertEqual(cMinor.diatonicQualities, [.minor, .diminished, .major, .minor, .minor, .major, .major])
    }

    func testMusicalKeyRomanNumeral() {
        let cMajor = MusicalKey(root: .C, mode: .major)

        let cChord = Chord(root: .C, quality: .major, confidence: 1.0, notes: [], timestamp: Date())
        XCTAssertEqual(cMajor.romanNumeral(for: cChord), "I")

        let gChord = Chord(root: .G, quality: .major, confidence: 1.0, notes: [], timestamp: Date())
        XCTAssertEqual(cMajor.romanNumeral(for: gChord), "V")

        let aChord = Chord(root: .A, quality: .minor, confidence: 1.0, notes: [], timestamp: Date())
        XCTAssertEqual(cMajor.romanNumeral(for: aChord), "vi")
    }

    // MARK: - SpelledNote

    func testSpelledNoteDisplayString() {
        let c = SpelledNote(letter: .C, accidental: .natural)
        XCTAssertEqual(c.displayString, "C")

        let bFlat = SpelledNote(letter: .B, accidental: .flat)
        XCTAssertEqual(bFlat.displayString, "B♭")

        let fSharp = SpelledNote(letter: .F, accidental: .sharp)
        XCTAssertEqual(fSharp.displayString, "F♯")
    }

    func testSpelledNotePitchClass() {
        let c = SpelledNote(letter: .C, accidental: .natural)
        XCTAssertEqual(c.pitchClass, 0)

        let bFlat = SpelledNote(letter: .B, accidental: .flat)
        XCTAssertEqual(bFlat.pitchClass, 10)

        let fSharp = SpelledNote(letter: .F, accidental: .sharp)
        XCTAssertEqual(fSharp.pitchClass, 6)
    }

    func testSpelledNoteNoteName() {
        let bFlat = SpelledNote(letter: .B, accidental: .flat)
        XCTAssertEqual(bFlat.noteName, .As)

        let fSharp = SpelledNote(letter: .F, accidental: .sharp)
        XCTAssertEqual(fSharp.noteName, .Fs)
    }

    func testLetterNameAdvanced() {
        let c = LetterName.C
        XCTAssertEqual(c.advanced(by: 0), .C)
        XCTAssertEqual(c.advanced(by: 1), .D)
        XCTAssertEqual(c.advanced(by: 4), .G)
        XCTAssertEqual(c.advanced(by: 7), .C) // wrapping
    }

    // MARK: - TheoryReference

    func testTheoryReferenceLoad() throws {
        let theory = try TheoryReference.load()

        XCTAssertFalse(theory.scales.isEmpty, "Scales should not be empty")
        XCTAssertFalse(theory.chordFormulas.isEmpty, "Chord formulas should not be empty")

        // Check that we have expected scales
        XCTAssertNotNil(theory.scales["major"])
        XCTAssertNotNil(theory.scales["natural_minor"])

        // Check that we have expected chord formulas
        XCTAssertNotNil(theory.chordFormulas["major"])
        XCTAssertNotNil(theory.chordFormulas["minor"])
    }

    func testTheoryReferenceShared() {
        let shared = TheoryReference.shared

        XCTAssertFalse(shared.scales.isEmpty)
        XCTAssertFalse(shared.chordFormulas.isEmpty)
        XCTAssertFalse(shared.intervals.isEmpty)
    }

    func testTheoryReferenceScalesHaveIntervals() throws {
        let theory = try TheoryReference.load()

        let majorScale = try XCTUnwrap(theory.scales["major"])
        XCTAssertNotNil(majorScale.intervals)
        XCTAssertEqual(majorScale.intervals, [0, 2, 4, 5, 7, 9, 11])
    }

    func testTheoryReferenceChordFormulasHaveSymbols() throws {
        let theory = try TheoryReference.load()

        let majorFormula = try XCTUnwrap(theory.chordFormulas["major"])
        XCTAssertEqual(majorFormula.symbol, "")
        XCTAssertEqual(majorFormula.intervals, [0, 4, 7])

        let minorFormula = try XCTUnwrap(theory.chordFormulas["minor"])
        XCTAssertEqual(minorFormula.symbol, "m")
    }

    // MARK: - ChordQuality

    func testChordQualityIntervals() {
        XCTAssertEqual(ChordQuality.major.intervals, [0, 4, 7])
        XCTAssertEqual(ChordQuality.minor.intervals, [0, 3, 7])
        XCTAssertEqual(ChordQuality.diminished.intervals, [0, 3, 6])
        XCTAssertEqual(ChordQuality.augmented.intervals, [0, 4, 8])
        XCTAssertEqual(ChordQuality.major7.intervals, [0, 4, 7, 11])
        XCTAssertEqual(ChordQuality.minor7.intervals, [0, 3, 7, 10])
        XCTAssertEqual(ChordQuality.dominant7.intervals, [0, 4, 7, 10])
    }

    func testChordQualityChromaTemplate() {
        let major = ChordQuality.major.chromaTemplate
        XCTAssertEqual(major.count, 12)
        XCTAssertEqual(major[0], 1.0) // root
        XCTAssertEqual(major[4], 1.0) // major third
        XCTAssertEqual(major[7], 1.0) // perfect fifth
        XCTAssertEqual(major[1], 0.0) // not in chord
    }

    // MARK: - Note

    func testNoteDisplayString() {
        let note = Note(name: .Cs, octave: 4, frequency: 277.18, centsDeviation: 0)
        XCTAssertEqual(note.displayString, "C♯4")
    }

    func testNoteMidiNumber() {
        let note = Note(name: .C, octave: 0, frequency: 16.35, centsDeviation: 0)
        XCTAssertEqual(note.midiNumber, 12) // C0 = MIDI 12

        let a4 = Note(name: .A, octave: 4, frequency: 440.0, centsDeviation: 0)
        XCTAssertEqual(a4.midiNumber, 69) // A4 = MIDI 69
    }

    func testMusicTheoryNoteFromFrequency() {
        let note = MusicTheory.noteFromFrequency(440.0)
        XCTAssertNotNil(note)
        XCTAssertEqual(note?.name, .A)
        XCTAssertEqual(note?.octave, 4)
        XCTAssertEqual(note?.midiNumber, 69)
    }

    func testMusicTheoryFrequencyForMidi() {
        let freq = MusicTheory.frequencyForMidi(69)
        XCTAssertEqual(freq, 440.0, accuracy: 0.01)
    }

    func testMusicTheoryFrequencyForNote() {
        let freq = MusicTheory.frequency(for: .A, octave: 4)
        XCTAssertEqual(freq, 440.0, accuracy: 0.01)
    }
}
