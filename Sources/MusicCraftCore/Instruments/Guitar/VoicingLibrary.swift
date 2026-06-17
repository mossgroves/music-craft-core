import Foundation

/// A library of guitar voicings indexed by chord name and tuning.
///
/// Backed by **chords-db** (`tombatossals/chords-db`, MIT, vendored verbatim as
/// `Resources/chords_db_guitar.json` — see `chords_db_LICENSE.txt`). chords-db ships 12 roots ×
/// ~86 qualities (3,283 fingering positions) including 41 slash / inversion voicings, so this
/// replaces the old "legacy Cantus curated subset" (6 qualities, no inversions, no license).
///
/// The public API is unchanged: `voicings(for:tuning:limit:)` still returns root-position voicings.
/// What's new is coverage (every `ChordQuality` now resolves, where the old data had only six) and
/// `voicingsWithInversions(for:tuning:limit:)`, which adds the slash voicings the voicing wheel turns.
public enum VoicingLibrary {
    /// Returns ranked playable voicings for a chord on a tuning (root position only).
    ///
    /// Non-standard tunings return an empty array (chords-db ships standard tuning only — fine for
    /// Sanctuary). Voicings are returned in chords-db's order (best/most-common first).
    ///
    /// - Parameters:
    ///   - chord: Target chord
    ///   - tuning: Guitar tuning (default: .standard)
    ///   - limit: Maximum number of voicings to return (default: 5)
    /// - Returns: Array of GuitarVoicing in rank order, or empty if chord/tuning not found
    public static func voicings(
        for chord: Chord,
        tuning: GuitarTuning = .standard,
        limit: Int = 5
    ) -> [GuitarVoicing] {
        guard tuning == .standard else { return [] }
        let clean = rootPositionPositions(for: chord)
            .map { GuitarVoicing(chord: chord, tuning: tuning, position: $0) }
            .filter { spellsChord($0, chord, allowingBass: false) }
        return Array(clean.prefix(limit))
    }

    /// Returns root-position voicings **plus** the chord's slash / inversion voicings — the pool the
    /// voicing wheel turns through (`Am`, plus `Am/C`, `Am/E`, …). Root-position voicings come first
    /// (up to `limit`), then one shape per distinct bass note for each available inversion. Each
    /// returned `GuitarVoicing` still carries the base chord; the wheel reads `bassNote` /
    /// `isInversion` / `slashDisplayName` off it to label the header.
    ///
    /// Inversions are ordered **chord-tone bass first** — true inversions (3rd / 5th / 7th in the
    /// bass, e.g. `Am/C`, `Am/E`) lead, then the descending-bassline slash chords (`Am/G`, `Am/F`).
    /// chords-db can list a dozen slash entries per chord; ordering this way lets the wheel take the
    /// front of the list and surface the *common* inversions (spec §7) without dumping all of them.
    ///
    /// chords-db only carries inversions for major, minor, dominant-7, and minor-9 qualities; other
    /// qualities return just their root-position voicings (same as `voicings(for:)`).
    ///
    /// - Parameters:
    ///   - chord: Target chord (the inversions are inversions OF this chord)
    ///   - tuning: Guitar tuning (default: .standard)
    ///   - limit: Maximum number of *root-position* voicings (default: 5); inversions are added on top
    /// - Returns: Root-position voicings followed by inversion voicings (chord-tone bass first)
    public static func voicingsWithInversions(
        for chord: Chord,
        tuning: GuitarTuning = .standard,
        limit: Int = 5
    ) -> [GuitarVoicing] {
        guard tuning == .standard else { return [] }

        let rootVoicings = rootPositionPositions(for: chord)
            .map { GuitarVoicing(chord: chord, tuning: tuning, position: $0) }
            .filter { spellsChord($0, chord, allowingBass: false) }
            .prefix(limit)

        // One shape per inversion bass — chords-db lists several positions per slash suffix; take
        // the first that spells the chord (the bass is its one permitted extra note). Keeps the
        // wheel to distinct bass colors and skips the occasional malformed slash entry.
        let inversionVoicings = inversionEntries(for: chord).compactMap { entry -> GuitarVoicing? in
            for position in entry.positions {
                let v = GuitarVoicing(chord: chord, tuning: tuning, position: position)
                if spellsChord(v, chord, allowingBass: true) { return v }
            }
            return nil
        }

        // Sort: chord-tone-bass inversions (real 1st/2nd/3rd inversions) before non-chord-tone slash
        // chords; stable within each group (chords-db order). The chord's pitch classes are root +
        // its quality intervals.
        let chordTones = Set(chord.quality.intervals.map { ((chord.root.rawValue + $0) % 12 + 12) % 12 })
        let sortedInversions = inversionVoicings.enumerated().sorted { a, b in
            let aTone = chordTones.contains(a.element.bassNote.rawValue)
            let bTone = chordTones.contains(b.element.bassNote.rawValue)
            if aTone != bTone { return aTone }   // chord tones first
            return a.offset < b.offset            // else keep chords-db order (stable)
        }.map { $0.element }

        return rootVoicings + sortedInversions
    }

    // MARK: - chords-db lookup

    /// Root-position fingering positions for a chord, via the chords-db root key + quality suffix.
    /// Tries the chord's canonical chords-db root spelling, then the enharmonic alternative, so a
    /// chord spelled sharp (A♯) still resolves the flat-spelled chords-db root (Bb) and vice versa.
    private static func rootPositionPositions(for chord: Chord) -> [VoicingPosition] {
        guard let suffix = chordsDBSuffix(for: chord.quality) else { return [] }
        for rootKey in chordsDBRootKeys(for: chord.root) {
            if let entry = cache[rootKey]?.first(where: { $0.suffix == suffix }) {
                return entry.positions
            }
        }
        return []
    }

    /// The chords-db inversion entries for a chord — suffixes shaped `<base>/<bass>` (e.g. `m/C`,
    /// `/E`, `7/G`) under the chord's root. Empty for qualities chords-db has no inversions for.
    private static func inversionEntries(for chord: Chord) -> [DecodedEntry] {
        guard let prefix = chordsDBInversionPrefix(for: chord.quality) else { return [] }
        let slashPrefix = prefix + "/"   // "" → "/E…", "m" → "m/C…", "7" → "7/G", "m9" → "m9/…"
        for rootKey in chordsDBRootKeys(for: chord.root) {
            if let entries = cache[rootKey] {
                let inversions = entries.filter { $0.suffix.hasPrefix(slashPrefix) }
                if !inversions.isEmpty { return inversions }
            }
        }
        return []
    }

    // MARK: - Musical correctness filter

    /// The pitch classes (0–11) a chord contains: root + each of its quality's intervals.
    private static func pitchClasses(of chord: Chord) -> Set<Int> {
        Set(chord.quality.intervals.map { ((chord.root.rawValue + $0) % 12 + 12) % 12 })
    }

    /// True when the voicing sounds ONLY notes that belong to the chord — the guard that keeps
    /// chords-db's rare malformed entries off the wheel (e.g. a "B♭m7" position that actually sounds
    /// A/G/C/E, or an augmented entry with a stray tone). A voicing may *omit* chord tones (guitarists
    /// routinely drop the 5th, and the root in jazz shapes) — that's fine; it just may never add a
    /// FOREIGN tone. For an inversion, `allowingBass` permits the one intended slash bass as an extra
    /// (so `Am/G` — A C E G — survives even though G isn't an Am triad tone).
    ///
    /// Safe to apply everywhere: verified that every root × all-16-qualities combination retains at
    /// least one passing voicing (ChordsDBImportTests), so no chord is left without a shape.
    private static func spellsChord(_ voicing: GuitarVoicing, _ chord: Chord, allowingBass: Bool) -> Bool {
        var allowed = pitchClasses(of: chord)
        if allowingBass { allowed.insert(voicing.bassNote.rawValue) }
        let sounded = Set(voicing.soundedMIDINotes.map { ((($0 % 12) + 12) % 12) })
        return sounded.isSubset(of: allowed)
    }

    // MARK: - Chord → chords-db key mapping

    /// chords-db root keys to try for a NoteName, canonical spelling first. chords-db spells some
    /// roots flat (Eb, Ab, Bb) and others sharp (Csharp, Fsharp); we try the canonical spelling and
    /// the enharmonic fallback so either spelling of an accidental root resolves.
    private static func chordsDBRootKeys(for note: NoteName) -> [String] {
        switch note {
        case .C:  return ["C"]
        case .Cs: return ["Csharp"]
        case .D:  return ["D"]
        case .Ds: return ["Eb"]
        case .E:  return ["E"]
        case .F:  return ["F"]
        case .Fs: return ["Fsharp"]
        case .G:  return ["G"]
        case .Gs: return ["Ab"]
        case .A:  return ["A"]
        case .As: return ["Bb"]
        case .B:  return ["B"]
        }
    }

    /// MCC `ChordQuality` → chords-db root-position suffix string. All 16 MCC qualities map to a
    /// chords-db suffix (verified present in the dataset's 86 suffixes), so every quality resolves.
    private static func chordsDBSuffix(for quality: ChordQuality) -> String? {
        switch quality {
        case .major:           return "major"
        case .minor:           return "minor"
        case .diminished:      return "dim"
        case .augmented:       return "aug"
        case .major7:          return "maj7"
        case .minor7:          return "m7"
        case .minorMajor7:     return "mmaj7"
        case .dominant7:       return "7"
        case .diminished7:     return "dim7"
        case .halfDiminished7: return "m7b5"
        case .sus2:            return "sus2"
        case .sus4:            return "sus4"
        case .add9:            return "add9"
        case .minor9:          return "m9"
        case .major9:          return "maj9"
        case .power:           return "5"
        }
    }

    /// The chords-db suffix *prefix* before the slash for a quality's inversions, or nil when
    /// chords-db carries none. Note chords-db labels inversions in lead-sheet shorthand (`m/C`,
    /// `/E`), so minor's prefix is "m" (not "minor") and major's is "" (suffix begins "/").
    private static func chordsDBInversionPrefix(for quality: ChordQuality) -> String? {
        switch quality {
        case .major:     return ""
        case .minor:     return "m"
        case .dominant7: return "7"
        case .minor9:    return "m9"
        default:         return nil
        }
    }

    // MARK: - Decode + cache (chords-db native shape)

    /// One decoded chord entry: a quality suffix and its fingering positions, under some root.
    private struct DecodedEntry {
        let suffix: String
        let positions: [VoicingPosition]
    }

    /// Decoded chords-db data, keyed by chords-db root key ("C", "Csharp", … "Bb", "B"). Decoded
    /// once, lazily, and cached for the process lifetime.
    private static let cache: [String: [DecodedEntry]] = { loadChordsDB() }()

    /// The bundled chords-db resource URL. Exposed `internal` so the import-verification test
    /// (`@testable import`) can re-decode the raw file — including the `midi` arrays this loader
    /// drops — to confirm every position's computed pitches match chords-db's own.
    static var chordsDBResourceURL: URL? {
        Bundle.module.url(forResource: "chords_db_guitar", withExtension: "json")
    }

    private static func loadChordsDB() -> [String: [DecodedEntry]] {
        guard let url = chordsDBResourceURL else {
            return [:]
        }
        do {
            let data = try Data(contentsOf: url)
            let file = try JSONDecoder().decode(ChordsDBFile.self, from: data)
            var out: [String: [DecodedEntry]] = [:]
            for (rootKey, entries) in file.chords {
                out[rootKey] = entries.map { entry in
                    DecodedEntry(
                        suffix: entry.suffix,
                        positions: entry.positions.map { $0.toVoicingPosition() }
                    )
                }
            }
            return out
        } catch {
            print("Failed to load chords-db guitar voicings: \(error)")
            return [:]
        }
    }
}

// MARK: - chords-db Decodable shape

/// The top level of chords-db's `guitar.json`. We only need `chords`; `keys`/`suffixes`/`tunings`
/// /`main` are ignored (the suffix list lives per-entry, and we map roots/qualities ourselves).
private struct ChordsDBFile: Decodable {
    let chords: [String: [ChordsDBEntry]]
}

/// One chord in chords-db: a root `key` (e.g. "C", "Csharp"), a `suffix` (e.g. "major", "m/C"),
/// and its fingering `positions`.
private struct ChordsDBEntry: Decodable {
    let key: String
    let suffix: String
    let positions: [ChordsDBPosition]
}

/// One fingering position in chords-db. The field shapes match MCC `VoicingPosition` 1:1 except
/// `midi` (sounded notes — used only for the import-verification test, dropped here) and `capo`
/// (maps to `requiresCapo`).
private struct ChordsDBPosition: Decodable {
    let frets: [Int]
    let fingers: [Int]
    let baseFret: Int
    let barres: [Int]?
    let capo: Bool?
    let midi: [Int]?

    /// Map to MCC's value type. `frets`/`fingers`/`baseFret`/`barres` are identical conventions
    /// (frets relative to baseFret, -1 mute / 0 open; barres are fret numbers relative to baseFret —
    /// confirmed against MCC's existing fixtures, 2026-06-17). `capo` → `requiresCapo`; `midi` dropped.
    func toVoicingPosition() -> VoicingPosition {
        VoicingPosition(
            frets: frets,
            fingers: fingers,
            baseFret: baseFret,
            barres: (barres?.isEmpty ?? true) ? nil : barres,
            requiresCapo: capo ?? false
        )
    }
}
