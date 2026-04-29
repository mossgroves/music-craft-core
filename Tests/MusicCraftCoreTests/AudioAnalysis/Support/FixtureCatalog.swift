import Foundation

/// Catalog of all SoundFont-based fixtures to generate for Phase 2 testing.
struct FixtureCatalog {
    /// All single-chord fixtures.
    static let singleChordFixtures: [ChordFixtureSpec] = {
        let voicings: [(String, GuitarVoicing)] = [
            ("C", .cMajor),
            ("Cm", .cMinor),
            ("D", .dMajor),
            ("Dm", .dMinor),
            ("E", .eMajor),
            ("Em", .eMinor),
            ("F", .fMajor),
            ("G", .gMajor),
            ("Gm", .gMinor),
            ("A", .aMajor),
            ("Am", .aMinor),
            ("B", .bMinor),  // Bm voicing used for B due to complexity of open B major
            ("Cmaj7", .cMaj7),
            ("Cmin7", .cMin7),
            ("C7", .c7),
        ]

        return voicings.map { chord, voicing in
            ChordFixtureSpec(chord: chord, voicing: voicing, duration: 4.0, velocity: 100, attackOffset: 0.0)
        }
    }()

    /// All progression fixtures.
    static let progressionFixtures: [ProgressionFixtureSpec] = {
        var fixtures: [ProgressionFixtureSpec] = []

        let progressions: [(name: String, chords: [(String, TimeInterval)], key: String)] = [
            // I-IV-V-I in various keys
            ("I-IV-V-I in C", [("C", 2), ("F", 2), ("G", 2), ("C", 2)], "C"),
            ("I-IV-V-I in G", [("G", 2), ("C", 2), ("D", 2), ("G", 2)], "G"),
            ("I-IV-V-I in D", [("D", 2), ("G", 2), ("A", 2), ("D", 2)], "D"),
            ("I-IV-V-I in A", [("A", 2), ("D", 2), ("E", 2), ("A", 2)], "A"),
            ("I-IV-V-I in E", [("E", 2), ("A", 2), ("B", 2), ("E", 2)], "E"),

            // vi-IV-I-V (sensitive progression)
            ("vi-IV-I-V in C", [("Am", 2), ("F", 2), ("C", 2), ("G", 2)], "C"),
            ("vi-IV-I-V in G", [("Em", 2), ("C", 2), ("G", 2), ("D", 2)], "G"),

            // ii-V-I (jazz turnaround)
            ("ii-V-I in C", [("Dm", 2), ("G", 2), ("C", 2)], "C"),
            ("ii-V-I in F", [("Gm", 2), ("C", 2), ("F", 2)], "F"),
            ("ii-V-I in G", [("Am", 2), ("D", 2), ("G", 2)], "G"),
        ]

        let tempos = [80.0, 100.0, 120.0]

        for (name, chords, key) in progressions {
            for tempo in tempos {
                let spec = ProgressionFixtureSpec(
                    name: "\(name) @ \(Int(tempo))BPM",
                    chords: chords,
                    tempo: tempo,
                    voicing: .cMajor,  // Placeholder; will be voicing-mapped per chord
                    key: key
                )
                fixtures.append(spec)
            }
        }

        return fixtures
    }()

    /// Single-note chromatic scale (C3 to C6).
    static let chromaticScaleFixture: ScaleFixtureSpec = {
        var notes: [UInt8] = []
        for octave in 3...5 {
            for semitone in 0..<12 {
                let midiNote = UInt8(12 * octave + semitone)
                notes.append(midiNote)
            }
        }
        return ScaleFixtureSpec(
            name: "Chromatic C3-C6",
            notes: notes,
            noteDuration: 0.3,
            velocity: 100,
            octaveStart: 3
        )
    }()

    /// All fixtures for generation.
    static func allFixtures() -> [(name: String, spec: Any)] {
        var all: [(String, Any)] = []

        for chord in singleChordFixtures {
            let filename = "chord-\(chord.chord.lowercased().replacingOccurrences(of: "#", with: "s"))"
            all.append((filename, chord))
        }

        for prog in progressionFixtures {
            let sanitized = prog.name
                .lowercased()
                .replacingOccurrences(of: " @ ", with: "-")
                .replacingOccurrences(of: " ", with: "-")
            let filename = "progression-\(sanitized)"
            all.append((filename, prog))
        }

        all.append(("scale-chromatic", chromaticScaleFixture))

        return all
    }
}
