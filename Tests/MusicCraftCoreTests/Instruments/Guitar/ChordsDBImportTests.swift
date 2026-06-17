import XCTest
@testable import MusicCraftCore

/// Verifies the chords-db import (adopted 2026-06-17, replacing the legacy curated subset).
///
/// The deterministic win: chords-db ships a `midi` array (the sounded pitches) per position. We
/// re-decode the raw bundled file, and for EVERY one of the ~3,283 positions confirm that the
/// pitches MCC computes from (tuning + frets) — the same code that powers `GuitarVoicing.bassNote`
/// and the slash-chord wheel header — exactly match chords-db's `midi`. If the fret→MIDI semantics
/// or the `VoicingPosition` mapping were wrong for any voicing, this catches it automatically.
final class ChordsDBImportTests: XCTestCase {

    // MARK: - Raw chords-db shape (with the midi field the loader drops)

    private struct RawFile: Decodable { let chords: [String: [RawEntry]] }
    private struct RawEntry: Decodable { let key: String; let suffix: String; let positions: [RawPosition] }
    private struct RawPosition: Decodable {
        let frets: [Int]; let fingers: [Int]; let baseFret: Int
        let barres: [Int]?; let capo: Bool?; let midi: [Int]
    }

    private func loadRaw() throws -> RawFile {
        let url = try XCTUnwrap(VoicingLibrary.chordsDBResourceURL, "chords-db resource not bundled")
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(RawFile.self, from: data)
    }

    // MARK: - The core verification

    /// For every chords-db position: the MIDI notes MCC computes from tuning + frets equal the
    /// `midi` array chords-db ships. Run across all roots, qualities, and positions — zero tolerance.
    func testEveryPositionComputesChordsDBMidi() throws {
        let file = try loadRaw()
        let placeholder = Chord(root: .C, quality: .major)  // soundedMIDINotes ignores the chord
        var checked = 0
        var mismatches: [String] = []

        for (rootKey, entries) in file.chords {
            for entry in entries {
                for (i, p) in entry.positions.enumerated() {
                    let position = VoicingPosition(
                        frets: p.frets, fingers: p.fingers, baseFret: p.baseFret,
                        barres: (p.barres?.isEmpty ?? true) ? nil : p.barres,
                        requiresCapo: p.capo ?? false
                    )
                    let voicing = GuitarVoicing(chord: placeholder, tuning: .standard, position: position)
                    if voicing.soundedMIDINotes != p.midi {
                        mismatches.append("\(rootKey)\(entry.suffix)[\(i)]: computed \(voicing.soundedMIDINotes) != midi \(p.midi)")
                    }
                    checked += 1
                }
            }
        }

        XCTAssertGreaterThan(checked, 3000, "Expected the full chords-db dataset (~3283 positions)")
        XCTAssertTrue(mismatches.isEmpty, "MIDI mismatches (\(mismatches.count)):\n" + mismatches.prefix(20).joined(separator: "\n"))
    }

    // MARK: - Lookups spell their chords

    /// Every root-position voicing the library returns sounds ONLY notes that belong to the chord —
    /// no foreign tones. (A voicing may omit chord tones; guitarists drop 5ths and roots. It may
    /// never ADD a wrong one.) This is the contract `VoicingLibrary.spellsChord` enforces, and it
    /// proves the filter drops chords-db's rare malformed positions (a "B♭m7" sounding A/G/C/E etc.)
    /// across every root × all 16 MCC qualities, while still leaving every chord at least one shape.
    func testRootPositionVoicingsSoundOnlyChordTones() {
        for root in NoteName.allCases {
            for quality in ChordQuality.allCases {
                let chord = Chord(root: root, quality: quality)
                let voicings = VoicingLibrary.voicings(for: chord, tuning: .standard, limit: 8)
                XCTAssertGreaterThan(voicings.count, 0,
                    "No voicings for \(chord.displayName) — chords-db should cover every quality")
                let allowed = Set(quality.intervals.map { ((root.rawValue + $0) % 12 + 12) % 12 })
                for v in voicings {
                    let sounded = Set(v.soundedMIDINotes.map { ((($0 % 12) + 12) % 12) })
                    XCTAssertTrue(
                        sounded.isSubset(of: allowed),
                        "\(chord.displayName) voicing \(v.position.frets)@\(v.position.baseFret) sounds \(sounded.sorted()) — foreign to \(allowed.sorted())"
                    )
                }
            }
        }
    }

    /// Inversion voicings carry the slash bass declared by chords-db's suffix: for every slash
    /// entry, the bass MCC computes from the frets matches the note named after the "/". Proves the
    /// slash-header semantics (`Am/C`) are grounded in the data, not guessed.
    func testInversionBassMatchesSlashSuffix() throws {
        let file = try loadRaw()
        let noteIndex: [String: Int] = [
            "C": 0, "C#": 1, "Db": 1, "D": 2, "D#": 3, "Eb": 3, "E": 4, "F": 5,
            "F#": 6, "Gb": 6, "G": 7, "G#": 8, "Ab": 8, "A": 9, "A#": 10, "Bb": 10, "B": 11
        ]
        var checked = 0
        for (_, entries) in file.chords {
            for entry in entries where entry.suffix.contains("/") {
                guard let slash = entry.suffix.split(separator: "/").last,
                      let expectedBassPC = noteIndex[String(slash)],
                      let first = entry.positions.first else { continue }
                let position = VoicingPosition(
                    frets: first.frets, fingers: first.fingers, baseFret: first.baseFret,
                    barres: (first.barres?.isEmpty ?? true) ? nil : first.barres,
                    requiresCapo: first.capo ?? false
                )
                // soundedMIDINotes ignores the chord, so a placeholder is fine for bass computation.
                let v = GuitarVoicing(chord: Chord(root: .C, quality: .major), tuning: .standard, position: position)
                XCTAssertEqual(v.bassNote.rawValue, expectedBassPC,
                    "Slash entry \(entry.key)\(entry.suffix): computed bass \(v.bassNote.displayName) != suffix bass \(slash)")
                checked += 1
            }
        }
        XCTAssertGreaterThan(checked, 30, "Expected chords-db's slash/inversion entries")
    }

    // MARK: - Inversions

    /// `voicingsWithInversions` surfaces slash voicings whose bass is not the root, and the
    /// chord-tone inversions (Am/C, Am/E) sort ahead of the others. Header text reads as slash.
    func testAminorInversionsExposedAndOrdered() {
        let am = Chord(root: .A, quality: .minor)
        let all = VoicingLibrary.voicingsWithInversions(for: am, tuning: .standard, limit: 5)

        let rootPos = all.filter { !$0.isInversion }
        let inversions = all.filter { $0.isInversion }
        XCTAssertGreaterThan(rootPos.count, 0, "Am should have root-position voicings")
        XCTAssertGreaterThan(inversions.count, 0, "Am should have inversion voicings from chords-db")

        // All root-position voicings come before any inversion (root-first contract).
        let firstInversionIndex = all.firstIndex { $0.isInversion } ?? all.count
        XCTAssertTrue(
            all[..<firstInversionIndex].allSatisfy { !$0.isInversion },
            "Root-position voicings must precede inversions"
        )

        // The natural inversions (bass on the 3rd = C, or the 5th = E) appear, with slash names.
        let bassNames = Set(inversions.map { $0.bassNote.displayName })
        XCTAssertTrue(bassNames.contains("C") || bassNames.contains("E"),
                      "Expected a chord-tone inversion (Am/C or Am/E); got \(bassNames.sorted())")
        if let amC = inversions.first(where: { $0.bassNote == .C }) {
            XCTAssertEqual(amC.slashDisplayName, "Am/C")
            XCTAssertTrue(amC.isInversion)
        }

        // Chord-tone-bass inversions sort ahead of non-chord-tone slash chords (Am/B, Am/D…).
        let chordTones: Set<Int> = [9, 0, 4]  // A, C, E
        let firstNonToneIdx = inversions.firstIndex { !chordTones.contains($0.bassNote.rawValue) }
        if let firstNonTone = firstNonToneIdx {
            XCTAssertTrue(
                inversions[..<firstNonTone].allSatisfy { chordTones.contains($0.bassNote.rawValue) },
                "Chord-tone inversions should lead the inversion list"
            )
        }
    }

    /// A root-position voicing reports the root as its bass and is not flagged an inversion.
    func testRootPositionIsNotInversion() {
        let c = Chord(root: .C, quality: .major)
        let openC = VoicingLibrary.voicings(for: c, tuning: .standard, limit: 1).first
        let v = try? XCTUnwrap(openC)
        XCTAssertEqual(v?.bassNote, .C)
        XCTAssertEqual(v?.isInversion, false)
        XCTAssertEqual(v?.slashDisplayName, "C")
    }
}
