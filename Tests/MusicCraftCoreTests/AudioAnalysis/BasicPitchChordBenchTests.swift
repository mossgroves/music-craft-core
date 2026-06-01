import XCTest
import AVFoundation
@testable import MusicCraftCore

/// DIAGNOSTIC, NON-ASSERTING head-to-head: the current chord path (`AudioExtractor.extract` →
/// `chordSegments.first`) vs. the **Basic-Pitch-notes→chords** route (transcribe → pitch-class
/// chroma over the whole clip → the same `ChordDetector` namer), on the existing GADA / TaylorNylon
/// labeled fixtures. This is a comparison to inform the Phase 2 chord-consolidation decision — it
/// prints a side-by-side summary and asserts **no accuracy threshold**, so it adds no pre-push gate.
///
/// The namer is built identically to `AudioExtractor` (see `AudioExtractor.swift`):
/// `ChordDetector(sampleRate:bufferSize: 8192, chromaTemplateLibrary: CanonicalChromaLibrary())`,
/// no classifier. The scoring mirrors `RealAudioChordTests` exactly (same fixtures, same labels,
/// same root/exact comparison) so the "current" column is directly comparable to that baseline.
///
/// Two known caveats (directional read — namer used as-is):
///  1. The template pre-filter is scale-invariant (cosine), but the reference re-rank and the
///     bass/harmonic suppression are scale-sensitive, so the chroma scaling here (max bin ≈ 1.0)
///     is a tuning detail, not a tuned choice.
///  2. `ChordDetector`'s built-in overtone/harmonic/sympathetic suppression was tuned for FFT
///     chroma and may over-suppress an already-clean note chroma. If the Basic Pitch numbers come
///     in surprisingly low, that suppression (`detectChord(chroma:)` always runs
///     `suppressHarmonicsAndSympathetic`) is the first thing to suspect.
final class BasicPitchVsCurrentChordBench: XCTestCase {

    private struct Tally {
        var root = 0
        var exact = 0
        var total = 0
        var confusions: [String: Int] = [:]
        var noChord = 0
    }

    // MARK: - The bench

    func testBasicPitchVsCurrentChordBench() throws {
        let gada = getFixturesDirectory(named: "real-audio/gada")
        let taylor = getFixturesDirectory(named: "real-audio/taylor-nylon")
        if gada == nil && taylor == nil {
            throw XCTSkip("GADA and TaylorNylon fixtures not available")
        }

        // Build both engines once. The Basic Pitch transcriber needs Core ML; skip if it can't load
        // (same posture as the model-dependent transcriber tests — the device/Xcode run is authoritative).
        let transcriber: BasicPitchTranscriber
        do {
            transcriber = try BasicPitchTranscriber()
        } catch {
            throw XCTSkip("Bundled Core ML model could not be loaded under this runner (\(error)); "
                + "the Basic Pitch route can't run here.")
        }
        // Namer built the same way AudioExtractor builds it (sampleRate/bufferSize are unused by the
        // chroma path of detectChord(chroma:), but we mirror the construction anyway).
        let namer = ChordDetector(sampleRate: 44100, bufferSize: 8192,
                                  chromaTemplateLibrary: CanonicalChromaLibrary())

        print("\n===== Chord namer head-to-head (diagnostic): current vs BP-chroma vs BP-note-native =====")

        if let gada {
            let files = gadaFiles(in: gada)
            let (cur, bpC, bpN) = run(files: files, transcriber: transcriber, namer: namer)
            printSummary(subset: "GADA", current: cur, bpChroma: bpC, bpNative: bpN)
        } else {
            print("GADA: fixtures not available (skipped)")
        }

        if let taylor {
            let files = taylorFiles(in: taylor)
            let (cur, bpC, bpN) = run(files: files, transcriber: transcriber, namer: namer)
            printSummary(subset: "TaylorNylon", current: cur, bpChroma: bpC, bpNative: bpN)
        } else {
            print("TaylorNylon: fixtures not available (skipped)")
        }

        print("=========================================================================\n")
        // Intentionally no XCTAssert — this is a comparison, not a gate.
    }

    // MARK: - Per-file three-way evaluation

    /// Score all three paths on the identical file set. Returns (current, bp-chroma, bp-note-native).
    private func run(files: [(url: URL, truth: String)],
                     transcriber: BasicPitchTranscriber,
                     namer: ChordDetector) -> (Tally, Tally, Tally) {
        var current = Tally()
        var bpChroma = Tally()
        var bpNative = Tally()

        for (url, truth) in files {
            // Parse the label through Chord(parsing:) so the comparison is canonical (pitch-class
            // root + quality enum) — enharmonic spelling can't cause a false miss.
            guard let truthChord = Chord(parsing: truth) else { continue }
            guard let (samples, sampleRate) = loadMono(url) else { continue }
            current.total += 1
            bpChroma.total += 1
            bpNative.total += 1

            // (1) Current path — exactly what RealAudioChordTests runs.
            let result = AudioExtractor.extract(buffer: samples, sampleRate: sampleRate)
            score(result.chordSegments.first?.chord, truth: truthChord, into: &current)

            // (2) + (3) share one transcription.
            if let transcription = try? transcriber.transcribe(samples, sampleRate: sampleRate) {
                // (2) Basic Pitch → whole-clip chroma → ChordDetector namer.
                score(namer.detectChord(chroma: chroma(from: transcription.notes))?.chord,
                      truth: truthChord, into: &bpChroma)
                // (3) Basic Pitch → weighted pitch-class histogram + bass → NoteChordIdentifier.
                let (hist, bass) = weighted(from: transcription.notes)
                score(NoteChordIdentifier.identify(weightedPitchClasses: hist, bassPitchClass: bass)?.chord,
                      truth: truthChord, into: &bpNative)
            } else {
                bpChroma.noChord += 1
                bpNative.noChord += 1
            }
        }
        return (current, bpChroma, bpNative)
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

    // MARK: - notes → chroma / histogram

    /// Un-normalized Σ duration×velocity per pitch class, plus the pitch class of the lowest-MIDI
    /// note as bass. `NoteChordIdentifier` normalizes internally (presence floor is relative to the
    /// max bin), so the absolute scale here doesn't matter.
    private func weighted(from notes: [TranscribedNote]) -> (hist: [Double], bass: Int?) {
        var bins = [Double](repeating: 0, count: 12)
        for n in notes { bins[((n.pitchMIDI % 12) + 12) % 12] += max(0, n.duration) * max(0, n.velocity) }
        let bass = notes.min(by: { $0.pitchMIDI < $1.pitchMIDI }).map { (($0.pitchMIDI % 12) + 12) % 12 }
        return (bins, bass)
    }


    /// 12-element pitch-class histogram: each note adds `duration × velocity` to bin
    /// `pitchMIDI % 12`. Normalized so the max bin ≈ 1.0 (same order as the namer's templates,
    /// whose root weight is 1.0). See caveat (1) in the class doc.
    func chroma(from notes: [TranscribedNote]) -> [Double] {
        var bins = [Double](repeating: 0, count: 12)
        for n in notes {
            let pc = ((n.pitchMIDI % 12) + 12) % 12
            bins[pc] += max(0, n.duration) * max(0, n.velocity)
        }
        let maxBin = bins.max() ?? 0
        guard maxBin > 0 else { return bins }
        return bins.map { $0 / maxBin }
    }

    // MARK: - Reporting

    private func printSummary(subset: String, current: Tally, bpChroma: Tally, bpNative: Tally) {
        func pct(_ n: Int, _ d: Int) -> String { d == 0 ? "n/a" : String(format: "%.1f%%", Double(n) / Double(d) * 100) }
        func line(_ label: String, _ t: Tally) -> String {
            "  \(label): root \(t.root)/\(t.total) = \(pct(t.root, t.total)), exact \(t.exact)/\(t.total) = \(pct(t.exact, t.total))  [noChord \(t.noChord)]"
        }
        func topConfusions(_ t: Tally) -> String {
            let top = t.confusions.sorted { $0.value > $1.value }.prefix(5).map { "\($0.key)×\($0.value)" }
            return top.isEmpty ? "(none)" : top.joined(separator: ", ")
        }
        print("""

        --- \(subset) (\(current.total) files) ---
        \(line("current       ", current))
        \(line("bp-chroma     ", bpChroma))
        \(line("bp-note-native", bpNative))
          bar to beat   : trained CreateML model projection ≈ 85–92% root on solo nylon
          current        confusions: \(topConfusions(current))
          bp-chroma      confusions: \(topConfusions(bpChroma))
          bp-note-native confusions: \(topConfusions(bpNative))
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
