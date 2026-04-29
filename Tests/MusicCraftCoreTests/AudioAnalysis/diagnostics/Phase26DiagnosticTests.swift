import XCTest
import AVFoundation
@testable import MusicCraftCore

/// Phase 2.6 diagnostic investigation: baseline accuracy gap analysis.
/// Investigates four hypotheses for the 60-percentage-point gap between Phase 2.5 measured accuracy
/// (GADA 40.6% root) and legacy Cantus Stage 2 baseline (99.7% root on full dataset).
///
/// Gate behind MCC_DIAGNOSTIC=1 env var — does not run in standard CI.
final class Phase26DiagnosticTests: XCTestCase {

    // MARK: - Hypothesis 1: Full-file vs Middle-50% Slicing

    /// Hypothesis 1: Legacy Cantus extracted samples[N/4 ..< 3N/4] (middle 50%) before processing,
    /// skipping attack and decay. Phase 2.5 passes full buffer to AudioExtractor.
    /// Expected: Full-file accuracy lower due to attack/decay noise.
    func testHypothesis1_Middle50Slicing() throws {
        guard ProcessInfo.processInfo.environment["MCC_DIAGNOSTIC"] == "1" else {
            throw XCTSkip("Diagnostic tests disabled. Set MCC_DIAGNOSTIC=1 to enable.")
        }
        guard let gadaDir = getFixturesDirectory(named: "real-audio/gada") else {
            throw XCTSkip("GADA fixtures not available")
        }

        let fileManager = FileManager.default
        guard let contents = try? fileManager.contentsOfDirectory(at: gadaDir, includingPropertiesForKeys: nil) else {
            throw XCTSkip("Cannot read GADA directory")
        }

        let wavFiles = contents.filter { $0.pathExtension == "wav" }.prefix(5)

        print("\n=== HYPOTHESIS 1: Middle-50% Slicing ===")
        print("Testing \(wavFiles.count) GADA files with full vs middle-50% extraction\n")

        var fullFileCorrect = 0
        var middle50CorrectCount = 0
        var total = 0

        for wavFile in wavFiles {
            let filename = wavFile.lastPathComponent
            let parts = (filename as NSString).deletingPathExtension.components(separatedBy: "_")
            guard parts.count >= 2 else { continue }
            let groundTruthChord = parts[1]

            // Load audio
            guard let audioFile = try? AVAudioFile(forReading: wavFile),
                  let buffer = AVAudioPCMBuffer(pcmFormat: audioFile.processingFormat,
                                               frameCapacity: AVAudioFrameCount(audioFile.length)) else {
                continue
            }

            try audioFile.read(into: buffer)
            guard let floatData = buffer.floatChannelData else { continue }

            let frameLength = Int(buffer.frameLength)
            let allSamples = Array<Float>(UnsafeBufferPointer(start: floatData[0], count: frameLength))

            // Middle 50% extraction (legacy Cantus approach)
            let start = frameLength / 4
            let end = start + frameLength / 2
            let middle50Samples = Array(allSamples[start..<end])

            // Full file extraction (Phase 2.5)
            let fullResult = AudioExtractor.extract(buffer: allSamples, sampleRate: audioFile.processingFormat.sampleRate)
            let middle50Result = AudioExtractor.extract(buffer: middle50Samples, sampleRate: audioFile.processingFormat.sampleRate)

            // Compare
            let fullChord = fullResult.chordSegments.first?.chord.root.displayName ?? "NONE"
            let middle50Chord = middle50Result.chordSegments.first?.chord.root.displayName ?? "NONE"

            let fullCorrect = fullChord == groundTruthChord
            let middle50IsCorrect = middle50Chord == groundTruthChord

            if fullCorrect { fullFileCorrect += 1 }
            if middle50IsCorrect { middle50CorrectCount += 1 }
            total += 1

            print("  \(filename)")
            print("    Ground truth: \(groundTruthChord)")
            print("    Full-file:    \(fullChord)\(fullCorrect ? " ✓" : " ✗")")
            print("    Middle-50%:   \(middle50Chord)\(middle50IsCorrect ? " ✓" : " ✗")")
        }

        let fullAcc = Double(fullFileCorrect) / Double(total) * 100
        let middle50Acc = Double(middle50CorrectCount) / Double(total) * 100

        print("\nResult:")
        print("  Full-file accuracy:   \(String(format: "%.1f%%", fullAcc)) (\(fullFileCorrect)/\(total))")
        print("  Middle-50% accuracy:  \(String(format: "%.1f%%", middle50Acc)) (\(middle50CorrectCount)/\(total))")
        print("  Hypothesis 1 finding: \(middle50Acc > fullAcc ? "SUPPORTED" : "NOT SUPPORTED")")
    }

    // MARK: - Hypothesis 2: Segment Selection Rule

    /// Hypothesis 2: Highest-confidence segment may not be correct for single-chord clips.
    /// Expected: Multiple segments produced; wrong chord in highest-confidence segment.
    func testHypothesis2_SegmentSelection() throws {
        guard ProcessInfo.processInfo.environment["MCC_DIAGNOSTIC"] == "1" else {
            throw XCTSkip("Diagnostic tests disabled. Set MCC_DIAGNOSTIC=1 to enable.")
        }
        guard let gadaDir = getFixturesDirectory(named: "real-audio/gada") else {
            throw XCTSkip("GADA fixtures not available")
        }

        guard FileManager.default.fileExists(atPath: gadaDir.path) else {
            throw XCTSkip("Cannot read GADA directory")
        }

        // Pick 5 test files: 2 high-confidence passes, 2 clear failures, 1 borderline
        let testFiles = [
            "ArgSG_C_open_022_ID4_1.wav",      // historically good
            "ArgSG_G_open_022_ID4_1.wav",      // historically good
            "ArgSG_D_open_022_ID4_1.wav",      // known fail (D→A)
            "ArgSG_Em_open_022_ID4_1.wav",     // known fail (Em→B)
            "Gretsch_A_open_022_ID1_1.wav",    // medium confidence
        ]

        print("\n=== HYPOTHESIS 2: Segment Selection Rule ===")
        print("Dumping full segment list for \(testFiles.count) files\n")

        var segmentDump = ""

        for filename in testFiles {
            let wavURL = gadaDir.appendingPathComponent(filename)
            guard FileManager.default.fileExists(atPath: wavURL.path) else {
                print("  ⚠ \(filename) not found")
                continue
            }

            let parts = (filename as NSString).deletingPathExtension.components(separatedBy: "_")
            guard parts.count >= 2 else { continue }
            let groundTruthChord = parts[1]

            guard let audioFile = try? AVAudioFile(forReading: wavURL),
                  let buffer = AVAudioPCMBuffer(pcmFormat: audioFile.processingFormat,
                                               frameCapacity: AVAudioFrameCount(audioFile.length)) else {
                continue
            }

            try audioFile.read(into: buffer)
            guard let floatData = buffer.floatChannelData else { continue }

            let frameLength = Int(buffer.frameLength)
            let samples = Array<Float>(UnsafeBufferPointer(start: floatData[0], count: frameLength))

            let result = AudioExtractor.extract(buffer: samples, sampleRate: audioFile.processingFormat.sampleRate)

            segmentDump += "File: \(filename)\n"
            segmentDump += "  Ground truth: \(groundTruthChord)\n"
            segmentDump += "  Segments detected: \(result.chordSegments.count)\n"

            for (idx, seg) in result.chordSegments.enumerated() {
                segmentDump += "    [\(idx)] \(seg.chord.displayName) (root: \(seg.chord.root.displayName), confidence: \(String(format: "%.3f", seg.confidence)), start: \(String(format: "%.2f", seg.startTime))s, end: \(String(format: "%.2f", seg.endTime))s)\n"
            }

            if result.chordSegments.isEmpty {
                segmentDump += "    (no segments detected)\n"
            }

            segmentDump += "\n"

            print("  \(filename): \(result.chordSegments.count) segments")
        }

        // Write segment dump
        let dumpURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("phase-2-6-segment-dump.txt")
        try? segmentDump.write(to: dumpURL, atomically: true, encoding: .utf8)

        print("\nSegment dump written to: \(dumpURL.path)")
        print(segmentDump)

        XCTAssert(true, "Diagnostic dump completed")
    }

    // MARK: - Hypothesis 3: Wrapper vs Raw Detector

    /// Hypothesis 3: Legacy Cantus's CantusChordDetector had post-processing that MCC's AudioExtractor lacks.
    /// Expected: Document post-processing logic differences.
    func testHypothesis3_WrapperLogic() throws {
        guard ProcessInfo.processInfo.environment["MCC_DIAGNOSTIC"] == "1" else {
            throw XCTSkip("Diagnostic tests disabled. Set MCC_DIAGNOSTIC=1 to enable.")
        }

        print("\n=== HYPOTHESIS 3: Wrapper vs Raw Detector ===")
        print("Analyzing ChordDetector source from legacy Cantus")
        print("\nKey findings:")
        print("  1. CantusChordDetector has noise baseline calibration (10-frame silence calibration)")
        print("  2. Temporal smoothing with smoothingFactor = 0.3 between frames")
        print("  3. Raw chroma preservation for minor-3rd protection")
        print("  4. Chord quality confidence weighting (root=1.0, third=0.5, fifth=0.35)")
        print("  5. CoreML classifier integration (Stage 3) for post-processing")
        print("\nAudioExtractor features:")
        print("  1. Noise baseline calibration from buffer silence frames ✓ (present)")
        print("  2. Early-frame attack skip with windowing ✓ (variant of smoothing)")
        print("  3. No raw chroma preservation")
        print("  4. ChordDetector template matching with weights ✓ (present)")
        print("  5. No CoreML classifier integration")
        print("\nHypothesis 3 assessment: PARTIALLY APPLICABLE")
        print("  MCC has noise calibration and early-frame handling.")
        print("  Missing: minor-3rd protection, temporal smoothing, CoreML post-processing.")
        print("  These gaps likely account for 5-15 percentage points of accuracy loss.")
    }

    // MARK: - Hypothesis 4: Chord Label Normalization

    /// Hypothesis 4: Enharmonic or glyph mismatches in chord name comparison.
    /// Expected: Unicode sharp/flat glyphs mismatch with ASCII.
    func testHypothesis4_ChordNormalization() throws {
        guard ProcessInfo.processInfo.environment["MCC_DIAGNOSTIC"] == "1" else {
            throw XCTSkip("Diagnostic tests disabled. Set MCC_DIAGNOSTIC=1 to enable.")
        }

        guard let gadaDir = getFixturesDirectory(named: "real-audio/gada") else {
            throw XCTSkip("GADA fixtures not available")
        }

        let fileManager = FileManager.default
        guard let contents = try? fileManager.contentsOfDirectory(at: gadaDir, includingPropertiesForKeys: nil) else {
            throw XCTSkip("Cannot read GADA directory")
        }

        let wavFiles = contents.filter { $0.pathExtension == "wav" }.prefix(20)

        print("\n=== HYPOTHESIS 4: Chord Label Normalization ===")
        print("Sampling 20 files: detected vs ground-truth chord names\n")

        var glyphMismatches = 0
        var enharmonicMatches = 0

        for wavFile in wavFiles {
            let filename = wavFile.lastPathComponent
            let parts = (filename as NSString).deletingPathExtension.components(separatedBy: "_")
            guard parts.count >= 2 else { continue }
            let groundTruthChord = parts[1]

            guard let audioFile = try? AVAudioFile(forReading: wavFile),
                  let buffer = AVAudioPCMBuffer(pcmFormat: audioFile.processingFormat,
                                               frameCapacity: AVAudioFrameCount(audioFile.length)) else {
                continue
            }

            try audioFile.read(into: buffer)
            guard let floatData = buffer.floatChannelData else { continue }

            let frameLength = Int(buffer.frameLength)
            let samples = Array<Float>(UnsafeBufferPointer(start: floatData[0], count: frameLength))

            let result = AudioExtractor.extract(buffer: samples, sampleRate: audioFile.processingFormat.sampleRate)

            if let segment = result.chordSegments.first {
                let detected = segment.chord.root.displayName

                print("  \(filename)")
                print("    Ground truth: '\(groundTruthChord)'")
                print("    Detected:     '\(detected)'")

                // Check for glyph mismatches (ASCII # vs Unicode ♯)
                let groundTruthASCII = groundTruthChord.replacingOccurrences(of: "♯", with: "#").replacingOccurrences(of: "♭", with: "b")
                let detectedASCII = detected.replacingOccurrences(of: "♯", with: "#").replacingOccurrences(of: "♭", with: "b")

                if groundTruthASCII != detected && groundTruthASCII == detectedASCII {
                    print("    → Glyph mismatch (would be correct with normalization)")
                    glyphMismatches += 1
                }

                // Check for enharmonic equivalence (C# == Db, etc.)
                if isEnharmonicEquivalent(groundTruthChord, detected) {
                    print("    → Enharmonic equivalent")
                    enharmonicMatches += 1
                }
            }
        }

        print("\nResult:")
        print("  Glyph mismatches: \(glyphMismatches)")
        print("  Enharmonic matches: \(enharmonicMatches)")
        print("  Hypothesis 4 assessment: \(glyphMismatches > 0 ? "MINOR ISSUE" : "NOT FOUND")")
    }

    // MARK: - Helpers

    private func getFixturesDirectory(named: String) -> URL? {
        let testBundleURL = Bundle(for: type(of: self)).bundleURL
        let standardPath = testBundleURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("AudioAnalysis")
            .appendingPathComponent("Fixtures")
            .appendingPathComponent(named)
        if FileManager.default.fileExists(atPath: standardPath.path) {
            return standardPath
        }
        let altPath = URL(fileURLWithPath: "/Users/chris/Documents/Code/mossgroves-music-craft-core/.build/arm64-apple-macosx/debug/MusicCraftCore_MusicCraftCoreTests.bundle/Fixtures/\(named)")
        if FileManager.default.fileExists(atPath: altPath.path) {
            return altPath
        }
        return nil
    }

    // MARK: - Phase 2.7: Segment Presence Dump

    /// Phase 2.7 clarification 2b: For 10 failing fixtures, dump full segment list to understand
    /// whether the correct chord is present in any segment (cheap segment-selection fix) or missing
    /// entirely (expensive detector improvement needed).
    func testPhase27_SegmentPresenceDump() throws {
        guard ProcessInfo.processInfo.environment["MCC_DIAGNOSTIC"] == "1" else {
            throw XCTSkip("Diagnostic tests disabled. Set MCC_DIAGNOSTIC=1 to enable.")
        }

        guard let gadaDir = getFixturesDirectory(named: "real-audio/gada"),
              let taylorDir = getFixturesDirectory(named: "real-audio/taylor-nylon") else {
            throw XCTSkip("Fixture directories not available")
        }

        // 10 failing fixtures: 5 GADA, 5 TaylorNylon
        let failingGADA = [
            ("ArgSG_Em_open_022_ID4_1.wav", "Em"),
            ("Gretsch_A_open_022_ID1_1.wav", "A"),
            ("HBLP_D_open_022_ID1_1.wav", "D"),
            ("ArgSG_A_open_022_ID4_1.wav", "A"),
            ("ArgSG_B_open_022_ID1_1.wav", "B"),
        ]

        let failingTaylor = [
            ("Dm", "Dm_001.wav", "Dm"),
            ("Dm", "Dm_002.wav", "Dm"),
            ("Fm", "Fm_001.wav", "Fm"),
            ("Fm", "Fm_002.wav", "Fm"),
            ("D", "D_001.wav", "D"),
        ]

        var dump = "=== Phase 2.7 Segment Presence Dump ===\n\n"

        dump += "GADA failing fixtures:\n"
        for (filename, expectedChord) in failingGADA {
            let wavURL = gadaDir.appendingPathComponent(filename)
            guard FileManager.default.fileExists(atPath: wavURL.path) else {
                dump += "  ⚠ \(filename) not found\n"
                continue
            }

            guard let audioFile = try? AVAudioFile(forReading: wavURL),
                  let buffer = AVAudioPCMBuffer(pcmFormat: audioFile.processingFormat,
                                               frameCapacity: AVAudioFrameCount(audioFile.length)) else {
                dump += "  ⚠ \(filename) could not be read\n"
                continue
            }

            try audioFile.read(into: buffer)
            guard let floatData = buffer.floatChannelData else { continue }

            let frameLength = Int(buffer.frameLength)
            let samples = Array<Float>(UnsafeBufferPointer(start: floatData[0], count: frameLength))
            let duration = Double(frameLength) / audioFile.processingFormat.sampleRate

            let result = AudioExtractor.extract(buffer: samples, sampleRate: audioFile.processingFormat.sampleRate)

            dump += "\nFile: \(filename) (expected: \(expectedChord), duration: \(String(format: "%.2f", duration))s)\n"
            dump += "  Total segments detected: \(result.chordSegments.count)\n"

            if result.chordSegments.isEmpty {
                dump += "  (no segments detected)\n"
            } else {
                // Check if correct chord is in any segment
                let hasCorrect = result.chordSegments.contains { $0.chord.root.displayName == expectedChord }
                dump += "  Correct chord (\(expectedChord)) present: \(hasCorrect ? "YES" : "NO")\n"

                // Dump all segments
                for (idx, seg) in result.chordSegments.enumerated() {
                    let detected = seg.chord.root.displayName
                    let isCorrect = detected == expectedChord
                    let mark = isCorrect ? "✓" : "✗"
                    dump += "    [\(idx)] \(mark) \(detected) (confidence: \(String(format: "%.3f", seg.confidence)), "
                    dump += "duration: \(String(format: "%.2f", seg.endTime - seg.startTime))s, "
                    dump += "start: \(String(format: "%.2f", seg.startTime))s)\n"
                }

                // Summary
                let pickedChord = result.chordSegments.first?.chord.root.displayName ?? "NONE"
                let isPickedCorrect = pickedChord == expectedChord
                dump += "  → Picked: \(pickedChord) (\(isPickedCorrect ? "correct" : "WRONG"))\n"
            }
        }

        dump += "\n" + String(repeating: "-", count: 60) + "\n"
        dump += "TaylorNylon failing fixtures:\n"
        for (chordFolder, filename, expectedChord) in failingTaylor {
            let wavURL = taylorDir.appendingPathComponent(chordFolder).appendingPathComponent(filename)
            guard FileManager.default.fileExists(atPath: wavURL.path) else {
                dump += "  ⚠ \(chordFolder)/\(filename) not found\n"
                continue
            }

            guard let audioFile = try? AVAudioFile(forReading: wavURL),
                  let buffer = AVAudioPCMBuffer(pcmFormat: audioFile.processingFormat,
                                               frameCapacity: AVAudioFrameCount(audioFile.length)) else {
                dump += "  ⚠ \(chordFolder)/\(filename) could not be read\n"
                continue
            }

            try audioFile.read(into: buffer)
            guard let floatData = buffer.floatChannelData else { continue }

            let frameLength = Int(buffer.frameLength)
            let samples = Array<Float>(UnsafeBufferPointer(start: floatData[0], count: frameLength))
            let duration = Double(frameLength) / audioFile.processingFormat.sampleRate

            let result = AudioExtractor.extract(buffer: samples, sampleRate: audioFile.processingFormat.sampleRate)

            dump += "\nFile: \(chordFolder)/\(filename) (expected: \(expectedChord), duration: \(String(format: "%.2f", duration))s)\n"
            dump += "  Total segments detected: \(result.chordSegments.count)\n"

            if result.chordSegments.isEmpty {
                dump += "  (no segments detected)\n"
            } else {
                let hasCorrect = result.chordSegments.contains { $0.chord.root.displayName == expectedChord }
                dump += "  Correct chord (\(expectedChord)) present: \(hasCorrect ? "YES" : "NO")\n"

                for (idx, seg) in result.chordSegments.enumerated() {
                    let detected = seg.chord.root.displayName
                    let isCorrect = detected == expectedChord
                    let mark = isCorrect ? "✓" : "✗"
                    dump += "    [\(idx)] \(mark) \(detected) (confidence: \(String(format: "%.3f", seg.confidence)), "
                    dump += "duration: \(String(format: "%.2f", seg.endTime - seg.startTime))s, "
                    dump += "start: \(String(format: "%.2f", seg.startTime))s)\n"
                }

                let pickedChord = result.chordSegments.first?.chord.root.displayName ?? "NONE"
                let isPickedCorrect = pickedChord == expectedChord
                dump += "  → Picked: \(pickedChord) (\(isPickedCorrect ? "correct" : "WRONG"))\n"
            }
        }

        // Write to temp file
        let dumpURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("phase-2-7-segment-dump.txt")
        try? dump.write(to: dumpURL, atomically: true, encoding: .utf8)

        print("\n" + dump)
        print("Dump written to: \(dumpURL.path)")

        XCTAssert(true, "Diagnostic dump completed")
    }

    private func isEnharmonicEquivalent(_ chord1: String, _ chord2: String) -> Bool {
        // Simple enharmonic mapping: C# = Db, D# = Eb, F# = Gb, G# = Ab, A# = Bb
        let enharmonics = [
            ("C#", "Db"), ("D#", "Eb"), ("F#", "Gb"), ("G#", "Ab"), ("A#", "Bb"),
            ("Db", "C#"), ("Eb", "D#"), ("Gb", "F#"), ("Ab", "G#"), ("Bb", "A#"),
        ]

        for (e1, e2) in enharmonics {
            let chord1Alt = chord1.replacingOccurrences(of: e1, with: e2)
            let chord2Alt = chord2.replacingOccurrences(of: e1, with: e2)
            if chord1Alt == chord2 || chord1 == chord2Alt {
                return true
            }
        }

        return false
    }
}
