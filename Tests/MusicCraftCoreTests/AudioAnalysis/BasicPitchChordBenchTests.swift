import XCTest
import AVFoundation
@testable import MusicCraftCore

/// DIAGNOSTIC, NON-ASSERTING validation of the `.basicPitch` chord path, on the existing GADA /
/// TaylorNylon labeled fixtures. As of 0.1.0 Basic Pitch + note-native is the only chord path (the
/// `.dsp` chroma+template `ChordDetector` column was removed with the DSP), so this bench compares two
/// views of the same engine:
///
///  1. **extract (integrated)** — `AudioExtractor.extract` → `chordSegments.first`: the full pipeline
///     (Basic Pitch transcription → 1 s windowed `noteNativeChordSegments` → `NoteChordIdentifier`).
///  2. **note-native (direct)** — Basic Pitch transcription → whole-clip weighted pitch-class histogram
///     + bass → `NoteChordIdentifier`: the namer applied directly to the whole clip.
///
/// They should track each other closely on these single-chord fixtures; a large gap flags a pipeline
/// integration regression (windowing / segment collapse). It prints a side-by-side summary and asserts
/// **no accuracy threshold**, so it adds no pre-push gate. Accuracy thresholds live in `RealAudioChordTests`.
final class BasicPitchChordBench: XCTestCase {

    private struct Tally {
        var root = 0
        var exact = 0
        var total = 0
        var confusions: [String: Int] = [:]
        var noChord = 0
    }

    // MARK: - The bench

    func testBasicPitchChordBench() throws {
        let gada = getFixturesDirectory(named: "real-audio/gada")
        let taylor = getFixturesDirectory(named: "real-audio/taylor-nylon")
        if gada == nil && taylor == nil {
            throw XCTSkip("GADA and TaylorNylon fixtures not available")
        }

        // The Basic Pitch transcriber needs Core ML; skip if it can't load (same posture as the
        // model-dependent transcriber tests — the device/Xcode run is authoritative).
        let transcriber: BasicPitchTranscriber
        do {
            transcriber = try BasicPitchTranscriber()
        } catch {
            throw XCTSkip("Bundled Core ML model could not be loaded under this runner (\(error)); "
                + "the Basic Pitch path can't run here.")
        }

        print("\n===== .basicPitch chord validation (diagnostic): integrated extract vs direct note-native =====")

        if let gada {
            let files = gadaFiles(in: gada)
            let (integrated, direct) = run(files: files, transcriber: transcriber)
            printSummary(subset: "GADA", integrated: integrated, direct: direct)
        } else {
            print("GADA: fixtures not available (skipped)")
        }

        if let taylor {
            let files = taylorFiles(in: taylor)
            let (integrated, direct) = run(files: files, transcriber: transcriber)
            printSummary(subset: "TaylorNylon", integrated: integrated, direct: direct)
        } else {
            print("TaylorNylon: fixtures not available (skipped)")
        }

        print("=========================================================================\n")
        // Intentionally no XCTAssert — this is a comparison, not a gate.
    }

    // MARK: - Per-file two-way evaluation

    /// Score both views on the identical file set. Returns (integrated, direct).
    private func run(files: [(url: URL, truth: String)],
                     transcriber: BasicPitchTranscriber) -> (Tally, Tally) {
        var integrated = Tally()
        var direct = Tally()

        for (url, truth) in files {
            // Parse the label through Chord(parsing:) so the comparison is canonical (pitch-class
            // root + quality enum) — enharmonic spelling can't cause a false miss.
            guard let truthChord = Chord(parsing: truth) else { continue }
            guard let (samples, sampleRate) = loadMono(url) else { continue }
            integrated.total += 1
            direct.total += 1

            // (1) Integrated path — the public extract pipeline (Basic Pitch + windowed note-native).
            let result = AudioExtractor.extract(buffer: samples, sampleRate: sampleRate)
            score(result.chordSegments.first?.chord, truth: truthChord, into: &integrated)

            // (2) Direct path — Basic Pitch → whole-clip weighted histogram + bass → NoteChordIdentifier.
            if let transcription = try? transcriber.transcribe(samples, sampleRate: sampleRate) {
                let (hist, bass) = weighted(from: transcription.notes)
                score(NoteChordIdentifier.identify(weightedPitchClasses: hist, bassPitchClass: bass)?.chord,
                      truth: truthChord, into: &direct)
            } else {
                direct.noChord += 1
            }
        }
        return (integrated, direct)
    }

    /// Corrected metric (both sides canonical `Chord`): root = pitch-class root match (any quality);
    /// exact = root AND quality match. A detected chord that misses is recorded as a confusion.
    private func score(_ detected: Chord?, truth: Chord, into t: inout Tally) {
        guard let detected else { t.noChord += 1; return }
        if detected.root == truth.root { t.root += 1 }
        if detected.root == truth.root && detected.quality == truth.quality {
            t.exact += 1
        } else {
            t.confusions["\(truth.displayName)→\(detected.displayName)", default: 0] += 1
        }
    }

    // MARK: - notes → histogram

    /// Un-normalized Σ duration×velocity per pitch class, plus the pitch class of the lowest-MIDI
    /// note as bass. `NoteChordIdentifier` normalizes internally (presence floor is relative to the
    /// max bin), so the absolute scale here doesn't matter.
    private func weighted(from notes: [TranscribedNote]) -> (hist: [Double], bass: Int?) {
        var bins = [Double](repeating: 0, count: 12)
        for n in notes { bins[((n.pitchMIDI % 12) + 12) % 12] += max(0, n.duration) * max(0, n.velocity) }
        let bass = notes.min(by: { $0.pitchMIDI < $1.pitchMIDI }).map { (($0.pitchMIDI % 12) + 12) % 12 }
        return (bins, bass)
    }

    // MARK: - Reporting

    private func printSummary(subset: String, integrated: Tally, direct: Tally) {
        func pct(_ n: Int, _ d: Int) -> String { d == 0 ? "n/a" : String(format: "%.1f%%", Double(n) / Double(d) * 100) }
        func line(_ label: String, _ t: Tally) -> String {
            "  \(label): root \(t.root)/\(t.total) = \(pct(t.root, t.total)), exact \(t.exact)/\(t.total) = \(pct(t.exact, t.total))  [noChord \(t.noChord)]"
        }
        func topConfusions(_ t: Tally) -> String {
            let top = t.confusions.sorted { $0.value > $1.value }.prefix(5).map { "\($0.key)×\($0.value)" }
            return top.isEmpty ? "(none)" : top.joined(separator: ", ")
        }
        print("""

        --- \(subset) (\(integrated.total) files) ---
        \(line("extract (integrated)", integrated))
        \(line("note-native (direct)", direct))
          extract     confusions: \(topConfusions(integrated))
          note-native confusions: \(topConfusions(direct))
        """)
    }

    // MARK: - Fixture loading (mirrors RealAudioChordTests)

    private func gadaFiles(in directory: URL) -> [(url: URL, truth: String)] {
        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return [] }
        var out: [(URL, String)] = []
        for wav in contents.filter({ $0.pathExtension == "wav" }) {
            if let label = parseGADAFilename(wav.lastPathComponent) { out.append((wav, label)) }
        }
        return out.sorted { $0.0.lastPathComponent < $1.0.lastPathComponent }
    }

    private func taylorFiles(in directory: URL) -> [(url: URL, truth: String)] {
        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return [] }
        var out: [(URL, String)] = []
        let folders = contents.filter { url in
            var isDir: ObjCBool = false
            fm.fileExists(atPath: url.path, isDirectory: &isDir)
            return isDir.boolValue
        }
        for folder in folders {
            let truth = folder.lastPathComponent
            guard let wavs = try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) else { continue }
            for wav in wavs where wav.pathExtension == "wav" { out.append((wav, truth)) }
        }
        return out.sorted { $0.0.lastPathComponent < $1.0.lastPathComponent }
    }

    private func parseGADAFilename(_ filename: String) -> String? {
        // Format: ArgSG_Am_open_022_ID4_1.wav → parts[1] is the chord label.
        let baseName = (filename as NSString).deletingPathExtension
        let parts = baseName.components(separatedBy: "_")
        guard parts.count >= 2 else { return nil }
        return parts[1]
    }

    private func loadMono(_ url: URL) -> (samples: [Float], sampleRate: Double)? {
        guard let audioFile = try? AVAudioFile(forReading: url),
              let buffer = AVAudioPCMBuffer(pcmFormat: audioFile.processingFormat,
                                            frameCapacity: AVAudioFrameCount(audioFile.length)),
              (try? audioFile.read(into: buffer)) != nil,
              let floatData = buffer.floatChannelData else { return nil }
        let n = Int(buffer.frameLength)
        let samples = Array(UnsafeBufferPointer(start: floatData[0], count: n))
        return (samples, audioFile.processingFormat.sampleRate)
    }

    private func getFixturesDirectory(named: String) -> URL? {
        let testBundleURL = Bundle(for: type(of: self)).bundleURL
        let standardPath = testBundleURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("AudioAnalysis")
            .appendingPathComponent("Fixtures")
            .appendingPathComponent(named)
        if FileManager.default.fileExists(atPath: standardPath.path) { return standardPath }

        let searchPaths = [
            "/Users/chris/Documents/Code/mossgroves-music-craft-core/.build/arm64-apple-macosx/debug/MusicCraftCore_MusicCraftCoreTests.bundle/Fixtures/\(named)",
        ]
        for path in searchPaths {
            let url = URL(fileURLWithPath: path)
            if FileManager.default.fileExists(atPath: url.path) { return url }
        }
        return nil
    }
}
