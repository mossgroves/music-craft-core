import Foundation
import AVFoundation

// Deferred — SoundFont rendering produces synthetic fixtures that don't exercise AudioExtractor's real-guitar tuning.
// Retained for future command-line tool target. Real-audio testing uses GADA and TaylorNylon datasets.

/// Generates SoundFont fixtures for Phase 2 testing infrastructure.
struct FixtureGenerator {
    enum Error: LocalizedError {
        case generationFailed(String)
        case outputDirectoryUnavailable
        case fixtureWriteFailed(String)

        var errorDescription: String? {
            switch self {
            case .generationFailed(let reason):
                return "Fixture generation failed: \(reason)"
            case .outputDirectoryUnavailable:
                return "Output directory unavailable"
            case .fixtureWriteFailed(let reason):
                return "Failed to write fixture: \(reason)"
            }
        }
    }

    /// Generate all fixtures from the catalog to the specified output directory.
    /// Idempotent: skips fixtures that already exist with matching content.
    static func generateAllFixtures(
        outputDirectory: URL,
        sampleRate: Double = 44100.0
    ) throws {
        // Ensure output directory exists
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true, attributes: nil)

        let fixtures = FixtureCatalog.allFixtures()

        for (fixtureID, spec) in fixtures {
            let baseFilename = fixtureID
            let wavURL = outputDirectory.appendingPathComponent("\(baseFilename).wav")
            let jsonURL = outputDirectory.appendingPathComponent("\(baseFilename).json")

            // Skip if fixture already exists
            if FileManager.default.fileExists(atPath: wavURL.path) &&
               FileManager.default.fileExists(atPath: jsonURL.path) {
                print("Skipping \(baseFilename) (already exists)")
                continue
            }

            print("Generating \(baseFilename)...")

            // Generate audio and ground truth based on spec type
            let (audio, groundTruth): ([Float], GroundTruth) = try generateFixture(spec, sampleRate: sampleRate)

            // Write WAV file
            try writeWAVFile(audio: audio, sampleRate: sampleRate, to: wavURL)

            // Write JSON ground truth
            let jsonData = try JSONEncoder().encode(GroundTruthCodable.from(groundTruth))
            try jsonData.write(to: jsonURL)

            print("  ✓ Generated \(baseFilename)")
        }

        print("All fixtures generated successfully.")
    }

    // MARK: - Fixture Generation

    private static func generateFixture(
        _ spec: Any,
        sampleRate: Double
    ) throws -> ([Float], GroundTruth) {
        if let chordSpec = spec as? ChordFixtureSpec {
            return try generateChordFixture(chordSpec, sampleRate: sampleRate)
        } else if let progSpec = spec as? ProgressionFixtureSpec {
            return try generateProgressionFixture(progSpec, sampleRate: sampleRate)
        } else if let scaleSpec = spec as? ScaleFixtureSpec {
            return try generateScaleFixture(scaleSpec, sampleRate: sampleRate)
        } else {
            throw Error.generationFailed("Unknown fixture spec type")
        }
    }

    private static func generateChordFixture(
        _ spec: ChordFixtureSpec,
        sampleRate: Double
    ) throws -> ([Float], GroundTruth) {
        // Generate MIDI events for the chord voicing
        let notes = spec.voicing.midiNotes
        let attackTime = spec.attackOffset
        let releaseTime = spec.duration

        var midiEvents: [MIDIEvent] = []

        // All notes on at attack time
        for note in notes {
            midiEvents.append(.noteOn(midiNote: note, velocity: spec.velocity, atSeconds: attackTime))
        }

        // All notes off at release time
        for note in notes {
            midiEvents.append(.noteOff(midiNote: note, atSeconds: releaseTime))
        }

        // Render via SoundFont
        let audio = try SoundFontRenderer.render(events: midiEvents, sampleRate: sampleRate)

        // Create ground truth
        let groundTruth = GroundTruth.singleChord(chord: spec.chord, confidence: 1.0)

        return (audio, groundTruth)
    }

    private static func generateProgressionFixture(
        _ spec: ProgressionFixtureSpec,
        sampleRate: Double
    ) throws -> ([Float], GroundTruth) {
        // Convert tempo (BPM) to beat duration (seconds)
        let beatDuration = 60.0 / spec.tempo  // Seconds per quarter note

        var midiEvents: [MIDIEvent] = []
        var currentTime = 0.0
        var chordSegments: [GroundTruth.ChordSegment] = []

        for (chordName, chordBeats) in spec.chords {
            let chordDuration = chordBeats * beatDuration
            let voicing = voicingForChord(chordName)
            let notes = voicing.midiNotes

            // All notes on at current time
            for note in notes {
                midiEvents.append(.noteOn(midiNote: note, velocity: 100, atSeconds: currentTime))
            }

            // All notes off at end of chord duration
            let endTime = currentTime + chordDuration
            for note in notes {
                midiEvents.append(.noteOff(midiNote: note, atSeconds: endTime))
            }

            // Record ground truth segment
            chordSegments.append(.init(
                chord: chordName,
                startTime: currentTime,
                endTime: endTime,
                confidence: 1.0
            ))

            currentTime = endTime
        }

        // Render via SoundFont
        let audio = try SoundFontRenderer.render(events: midiEvents, sampleRate: sampleRate)

        // Create ground truth
        let groundTruth = GroundTruth.chordProgression(segments: chordSegments)

        return (audio, groundTruth)
    }

    private static func generateScaleFixture(
        _ spec: ScaleFixtureSpec,
        sampleRate: Double
    ) throws -> ([Float], GroundTruth) {
        var midiEvents: [MIDIEvent] = []
        var noteAnnotations: [GroundTruth.NoteAnnotation] = []
        var currentTime = 0.0

        for midiNote in spec.notes {
            // Note on
            midiEvents.append(.noteOn(midiNote: midiNote, velocity: spec.velocity, atSeconds: currentTime))

            // Note off at end of duration
            let endTime = currentTime + spec.noteDuration
            midiEvents.append(.noteOff(midiNote: midiNote, atSeconds: endTime))

            // Record ground truth
            noteAnnotations.append(.init(
                midiNote: Int(midiNote),
                onsetTime: currentTime,
                duration: spec.noteDuration,
                confidence: 1.0
            ))

            currentTime = endTime
        }

        // Render via SoundFont
        let audio = try SoundFontRenderer.render(events: midiEvents, sampleRate: sampleRate)

        // Create ground truth
        let groundTruth = GroundTruth.melodyNotes(notes: noteAnnotations)

        return (audio, groundTruth)
    }

    // MARK: - Helpers

    private static func voicingForChord(_ chordName: String) -> GuitarVoicing {
        switch chordName.lowercased() {
        case "c": return .cMajor
        case "cm": return .cMinor
        case "d": return .dMajor
        case "dm": return .dMinor
        case "e": return .eMajor
        case "em": return .eMinor
        case "f": return .fMajor
        case "g": return .gMajor
        case "gm": return .gMinor
        case "a": return .aMajor
        case "am": return .aMinor
        case "b", "bm": return .bMinor
        case "cmaj7": return .cMaj7
        case "cmin7", "cm7": return .cMin7
        case "c7": return .c7
        default: return .cMajor
        }
    }

    // MARK: - WAV Writing

    private static func writeWAVFile(
        audio: [Float],
        sampleRate: Double,
        to url: URL
    ) throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)
        guard let format = format else {
            throw Error.fixtureWriteFailed("Invalid audio format")
        }

        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(audio.count))
        guard let buffer = buffer else {
            throw Error.fixtureWriteFailed("Failed to create audio buffer")
        }

        buffer.frameLength = AVAudioFrameCount(audio.count)
        let floatChannelData = buffer.floatChannelData!
        for i in 0..<audio.count {
            floatChannelData[0][i] = audio[i]
        }

        let audioFile = try AVAudioFile(forWriting: url, settings: format.settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        try audioFile.write(from: buffer)
    }
}

// MARK: - Codable Ground Truth for JSON serialization

struct GroundTruthCodable: Codable {
    enum CaseType: String, Codable {
        case singleChord
        case chordProgression
        case tempo
        case melodyNotes
        case lyrics
    }

    let type: CaseType
    let data: [String: AnyCodable]

    static func from(_ groundTruth: GroundTruth) -> GroundTruthCodable {
        switch groundTruth {
        case .singleChord(let chord, let confidence):
            return GroundTruthCodable(
                type: .singleChord,
                data: ["chord": AnyCodable(chord), "confidence": AnyCodable(confidence)]
            )

        case .chordProgression(let segments):
            let segmentData = segments.map { seg -> [String: AnyCodable] in
                [
                    "chord": AnyCodable(seg.chord),
                    "startTime": AnyCodable(seg.startTime),
                    "endTime": AnyCodable(seg.endTime),
                    "confidence": AnyCodable(seg.confidence)
                ]
            }
            return GroundTruthCodable(
                type: .chordProgression,
                data: ["segments": AnyCodable(segmentData)]
            )

        case .tempo(let bpm):
            return GroundTruthCodable(
                type: .tempo,
                data: ["bpm": AnyCodable(bpm)]
            )

        case .melodyNotes(let notes):
            let noteData = notes.map { note -> [String: AnyCodable] in
                [
                    "midiNote": AnyCodable(note.midiNote),
                    "onsetTime": AnyCodable(note.onsetTime),
                    "duration": AnyCodable(note.duration),
                    "confidence": AnyCodable(note.confidence)
                ]
            }
            return GroundTruthCodable(
                type: .melodyNotes,
                data: ["notes": AnyCodable(noteData)]
            )

        default:
            return GroundTruthCodable(type: .singleChord, data: [:])
        }
    }
}

/// Type-erased Codable wrapper
enum AnyCodable: Codable {
    case int(Int)
    case double(Double)
    case string(String)
    case array([AnyCodable])
    case dictionary([String: AnyCodable])

    init<T: Codable>(_ value: T) {
        if let v = value as? Int {
            self = .int(v)
        } else if let v = value as? Double {
            self = .double(v)
        } else if let v = value as? String {
            self = .string(v)
        } else if let v = value as? [AnyCodable] {
            self = .array(v)
        } else if let v = value as? [String: AnyCodable] {
            self = .dictionary(v)
        } else {
            self = .string(String(describing: value))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .int(let v):
            try container.encode(v)
        case .double(let v):
            try container.encode(v)
        case .string(let v):
            try container.encode(v)
        case .array(let v):
            try container.encode(v)
        case .dictionary(let v):
            try container.encode(v)
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let v = try? container.decode(Int.self) {
            self = .int(v)
        } else if let v = try? container.decode(Double.self) {
            self = .double(v)
        } else if let v = try? container.decode(String.self) {
            self = .string(v)
        } else if let v = try? container.decode([AnyCodable].self) {
            self = .array(v)
        } else if let v = try? container.decode([String: AnyCodable].self) {
            self = .dictionary(v)
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Cannot decode AnyCodable")
        }
    }
}
