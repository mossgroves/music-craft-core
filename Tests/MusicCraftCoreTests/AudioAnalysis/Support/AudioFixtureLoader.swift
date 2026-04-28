import Foundation
import MusicCraftCore

/// Loads audio fixtures (both synthetic and real-audio) for testing.
struct AudioFixtureLoader {
    struct Fixture {
        let samples: [Float]
        let sampleRate: Double
        let duration: TimeInterval
        let groundTruth: GroundTruth?
    }

    /// Load a synthetic fixture by name.
    static func loadSynthetic(_ name: String) -> Fixture? {
        switch name {
        case "all-major-triads":
            return synthecticAllMajorTriads()

        case "all-minor-triads":
            return syntheticAllMinorTriads()

        case "common-sevenths":
            return syntheticCommonSevenths()

        case "steady-80bpm":
            return syntheticTempo(bpm: 80)

        case "steady-120bpm":
            return syntheticTempo(bpm: 120)

        case "steady-140bpm":
            return syntheticTempo(bpm: 140)

        case "c-major-scale":
            return syntheticCMajorScale()

        default:
            return nil
        }
    }

    // MARK: - Synthetic Chord Fixtures

    private static func synthecticAllMajorTriads() -> Fixture {
        let chordDuration = 0.8
        let sampleRate44k = 44100.0

        // C C# D D# E F F# G G# A A# B
        let notes = [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11]
        let cMajor = 262.0  // C4 fundamental

        var allSamples: [Float] = []
        var segments: [GroundTruth.ChordSegment] = []
        var currentTime = 0.0

        for note in notes {
            let root = cMajor * pow(2.0, Double(note) / 12.0)
            let third = root * pow(2.0, 4.0 / 12.0)  // major 3rd
            let fifth = root * pow(2.0, 7.0 / 12.0)  // perfect 5th

            let chordBuffer = SyntheticGenerator.generateChordBuffer(
                frequencies: [root, third, fifth],
                duration: chordDuration,
                sampleRate: sampleRate44k
            )

            allSamples.append(contentsOf: chordBuffer)

            let chordNames = ["C", "C♯", "D", "D♯", "E", "F", "F♯", "G", "G♯", "A", "A♯", "B"]
            segments.append(.init(
                chord: chordNames[note],
                startTime: currentTime,
                endTime: currentTime + chordDuration,
                confidence: 1.0
            ))

            currentTime += chordDuration
        }

        return Fixture(
            samples: allSamples,
            sampleRate: sampleRate44k,
            duration: currentTime,
            groundTruth: .chordProgression(segments: segments)
        )
    }

    private static func syntheticAllMinorTriads() -> Fixture {
        let chordDuration = 0.8
        let sampleRate44k = 44100.0

        let notes = [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11]
        let cMajor = 262.0

        var allSamples: [Float] = []
        var segments: [GroundTruth.ChordSegment] = []
        var currentTime = 0.0

        for note in notes {
            let root = cMajor * pow(2.0, Double(note) / 12.0)
            let third = root * pow(2.0, 3.0 / 12.0)  // minor 3rd
            let fifth = root * pow(2.0, 7.0 / 12.0)  // perfect 5th

            let chordBuffer = SyntheticGenerator.generateChordBuffer(
                frequencies: [root, third, fifth],
                duration: chordDuration,
                sampleRate: sampleRate44k
            )

            allSamples.append(contentsOf: chordBuffer)

            let chordNames = ["Cm", "C♯m", "Dm", "D♯m", "Em", "Fm", "F♯m", "Gm", "G♯m", "Am", "A♯m", "Bm"]
            segments.append(.init(
                chord: chordNames[note],
                startTime: currentTime,
                endTime: currentTime + chordDuration,
                confidence: 1.0
            ))

            currentTime += chordDuration
        }

        return Fixture(
            samples: allSamples,
            sampleRate: sampleRate44k,
            duration: currentTime,
            groundTruth: .chordProgression(segments: segments)
        )
    }

    private static func syntheticCommonSevenths() -> Fixture {
        let sampleRate44k = 44100.0
        let chordDuration = 1.0
        let cMajor = 262.0

        var allSamples: [Float] = []
        var segments: [GroundTruth.ChordSegment] = []
        var currentTime = 0.0

        let seventhChords = [
            ("Cmaj7", [0.0, 4.0, 7.0, 11.0]),
            ("Cm7", [0.0, 3.0, 7.0, 10.0]),
            ("C7", [0.0, 4.0, 7.0, 10.0]),
            ("Cdim7", [0.0, 3.0, 6.0, 9.0]),
            ("Caug7", [0.0, 4.0, 8.0, 10.0]),
        ]

        for (name, intervals) in seventhChords {
            let root = cMajor
            let frequencies = intervals.map { root * pow(2.0, $0 / 12.0) }

            let chordBuffer = SyntheticGenerator.generateChordBuffer(
                frequencies: frequencies,
                duration: chordDuration,
                sampleRate: sampleRate44k
            )

            allSamples.append(contentsOf: chordBuffer)

            segments.append(.init(
                chord: name,
                startTime: currentTime,
                endTime: currentTime + chordDuration,
                confidence: 1.0
            ))

            currentTime += chordDuration
        }

        return Fixture(
            samples: allSamples,
            sampleRate: sampleRate44k,
            duration: currentTime,
            groundTruth: .chordProgression(segments: segments)
        )
    }

    // MARK: - Synthetic Tempo Fixtures

    private static func syntheticTempo(bpm: Int) -> Fixture {
        let durationSeconds = 8.0
        let sampleRate44k = 44100.0

        let samples = SyntheticGenerator.generateMetronomeClick(
            bpm: bpm,
            durationSeconds: durationSeconds,
            sampleRate: sampleRate44k
        )

        return Fixture(
            samples: samples,
            sampleRate: sampleRate44k,
            duration: durationSeconds,
            groundTruth: .tempo(bpm: bpm)
        )
    }

    // MARK: - Synthetic Scale/Melody Fixtures

    private static func syntheticCMajorScale() -> Fixture {
        let sampleRate44k = 44100.0
        let noteDuration = 0.4
        let cMajor = 262.0

        // C D E F G A B C
        let scaleIntervals = [0, 2, 4, 5, 7, 9, 11, 12]
        var allSamples: [Float] = []
        var notes: [GroundTruth.NoteAnnotation] = []
        var currentTime = 0.0

        for interval in scaleIntervals {
            let frequency = cMajor * pow(2.0, Double(interval) / 12.0)
            let sineWave = SyntheticGenerator.generateSineWave(
                frequency: frequency,
                duration: noteDuration,
                sampleRate: sampleRate44k
            )

            allSamples.append(contentsOf: sineWave)

            // MIDI note number: C4 = 60, so C4 + interval semitones
            let midiNote = 60 + interval
            notes.append(.init(
                midiNote: midiNote,
                onsetTime: currentTime,
                duration: noteDuration,
                confidence: 1.0
            ))

            currentTime += noteDuration
        }

        return Fixture(
            samples: allSamples,
            sampleRate: sampleRate44k,
            duration: currentTime,
            groundTruth: .melodyNotes(notes: notes)
        )
    }
}
