import XCTest
import Foundation
import AVFoundation
import MusicCraftCore

/// Phase 3.1 Diagnostic: Introspect AudioExtractor on one fixture to understand the 0% failure
final class Phase31DiagnosticTests: XCTestCase {
    func testDiagnosticOnBossaNova() throws {
        let fixtureDir = URL(fileURLWithPath: "/Users/chris/Documents/Code/mossgroves-music-craft-core/Tests/MusicCraftCoreTests/AudioAnalysis/Fixtures/real-audio/guitarset")
        let fixtureID = "00_BN1-129-Eb_comp"

        // Load audio
        let audioURL = fixtureDir.appendingPathComponent("\(fixtureID).wav")
        let jamsURL = fixtureDir.appendingPathComponent("\(fixtureID).jams")

        let audioFile = try AVAudioFile(forReading: audioURL)
        print("\n=== AUDIO LOADING ===")
        print("File: \(audioURL.lastPathComponent)")
        print("Duration (frames): \(audioFile.length)")
        print("Sample rate (Hz): \(audioFile.processingFormat.sampleRate)")
        print("Channels: \(audioFile.processingFormat.channelCount)")

        guard let buffer = AVAudioPCMBuffer(pcmFormat: audioFile.processingFormat, frameCapacity: UInt32(audioFile.length)) else {
            throw NSError(domain: "Audio", code: -1, userInfo: ["msg": "Buffer alloc failed"])
        }

        try audioFile.read(into: buffer)
        guard let floatChannelData = buffer.floatChannelData else {
            throw NSError(domain: "Audio", code: -1, userInfo: ["msg": "No float data"])
        }

        let frameLength = Int(buffer.frameLength)
        let samples = Array(UnsafeBufferPointer(start: floatChannelData[0], count: frameLength))
        let sampleRate = audioFile.processingFormat.sampleRate

        // Buffer stats
        print("\n=== BUFFER STATS ===")
        let minVal = samples.min() ?? 0
        let maxVal = samples.max() ?? 0
        let sumVal = samples.reduce(0.0) { $0 + Double($1) }
        let meanVal = sumVal / Double(samples.count)
        let sumSquares = samples.reduce(0.0) { $0 + Double($1 * $1) }
        let rmsVal = sqrt(sumSquares / Double(samples.count))
        print("Min amplitude: \(minVal)")
        print("Max amplitude: \(maxVal)")
        print("Mean amplitude: \(meanVal)")
        print("RMS amplitude: \(rmsVal)")
        if maxVal > 0 {
            print("Peak dBFS: \(20 * log10(maxVal))")
        }
        if rmsVal > 0 {
            print("RMS dBFS: \(20 * log10(rmsVal))")
        }

        // Run AudioExtractor
        print("\n=== AUDIO EXTRACTOR ===")
        let result = AudioExtractor.extract(buffer: samples, sampleRate: sampleRate)

        print("Duration: \(result.duration) sec")
        print("Chord segments: \(result.chordSegments.count)")
        for (i, seg) in result.chordSegments.enumerated() {
            print("  [\(i)]: \(seg.chord.displayName) [\(String(format: "%.2f", seg.confidence))] \(String(format: "%.2f", seg.startTime))–\(String(format: "%.2f", seg.endTime)) sec (\(seg.detectionMethod.rawValue))")
        }

        print("Detected notes: \(result.detectedNotes.count)")
        for (i, note) in result.detectedNotes.prefix(5).enumerated() {
            print("  [\(i)]: MIDI \(note.midiNote) [\(String(format: "%.2f", note.confidence))] \(String(format: "%.2f", note.onsetTime))–\(String(format: "%.2f", note.duration)) sec")
        }
        if result.detectedNotes.count > 5 {
            print("  ... and \(result.detectedNotes.count - 5) more")
        }

        print("Contour notes: \(result.contour.count)")
        if let key = result.key {
            print("Detected key: \(key.displayName)")
        } else {
            print("Detected key: nil")
        }

        // Test TempoEstimator directly
        print("\n=== TEMPO ESTIMATOR (DIRECT) ===")
        let tempoResults = TempoEstimator.estimateTempo(buffer: samples, sampleRate: sampleRate)
        if let firstTempo = tempoResults.first {
            print("Detected tempo: \(String(format: "%.1f", firstTempo.bpm)) BPM (confidence: \(String(format: "%.2f", firstTempo.confidence)))")
        } else {
            print("Detected tempo: nil")
        }

        // Test BeatTracker directly
        print("\n=== BEAT TRACKER (DIRECT) ===")
        let beats = BeatTracker.detectBeats(buffer: samples, sampleRate: sampleRate)
        print("Detected beats: \(beats.count)")
        for (i, beat) in beats.prefix(10).enumerated() {
            print("  [\(i)]: \(String(format: "%.2f", beat)) sec")
        }
        if beats.count > 10 {
            print("  ... and \(beats.count - 10) more")
        }

        // Load JAMS for ground truth
        let jamsData = try Data(contentsOf: jamsURL)
        let jamsDecoded = try JSONSerialization.jsonObject(with: jamsData) as? [String: Any]
        guard let jamsDecoded = jamsDecoded else { throw NSError(domain: "JAMS", code: -1, userInfo: nil) }

        // Ground truth from JAMS
        print("\n=== GROUND TRUTH (JAMS) ===")
        if let annotations = jamsDecoded["annotations"] as? [[String: Any]] {
            for ann in annotations {
                if let namespace = ann["namespace"] as? String {
                    if namespace == "chord_harte" {
                        if let data = ann["data"] as? [[String: Any]] {
                            let chords = data.compactMap { d in
                                (d["value"] as? [String: Any])?["chord"] as? String
                            }
                            print("JAMS chords: \(Set(chords).count) unique from \(chords.count) total")
                        }
                    } else if namespace == "beat" {
                        if let data = ann["data"] as? [[String: Any]] {
                            print("JAMS beats: \(data.count)")
                        }
                    } else if namespace == "key_mode" {
                        if let data = ann["data"] as? [[String: Any]] {
                            if let keyVal = data.first?["value"] as? String {
                                print("JAMS key: \(keyVal)")
                            }
                        }
                    }
                }
            }
        }

        print("\n=== SUMMARY ===")
        print("Audio loaded: ✓ (RMS \(String(format: "%.3f", rmsVal)) is \(rmsVal > 0.01 ? "MEANINGFUL" : "LOW/SUSPICIOUS"))")
        print("Chords detected: \(result.chordSegments.isEmpty ? "✗ ZERO" : "✓ \(result.chordSegments.count)")")
        print("Onsets detected: \(result.chordSegments.isEmpty && result.detectedNotes.isEmpty ? "✗ Likely ZERO" : "✓ Likely present")")
        print("Tempo detected: \(tempoResults.isEmpty ? "✗ nil" : "✓ \(String(format: "%.1f", tempoResults.first!.bpm)) BPM")")
        print("Beats detected: \(beats.isEmpty ? "✗ ZERO" : "✓ \(beats.count)")")

        // Assertions to make test pass and provide output
        XCTAssert(true, "Diagnostic complete")
    }
}
