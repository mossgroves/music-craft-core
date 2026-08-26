import XCTest
@testable import MusicCraftCore

/// Tests for `BasicPitchTranscriber` (Basic Pitch adoption; spec `specs/0.0.14-basic-pitch-adoption.md`).
///
/// Two tiers:
///  - **Pure** (always run on the CLI): the vDSP resampler and the ported note decoder.
///    These validate the adapted algorithm without Core ML.
///  - **Model-dependent** (load + run the bundled Core ML model): these `XCTSkip` if Core ML
///    model loading isn't available under the test runner, rather than fail — the authoritative
///    model validation is the device/Xcode step.
final class BasicPitchTranscriberTests: XCTestCase {

    // MARK: - Pure: resampler (bounds + behavior)

    func testResampleEmptyReturnsEmpty() {
        XCTAssertTrue(BasicPitchTranscriber.resample([], from: 44100, to: 22050).isEmpty)
    }

    func testResamplePassthroughWhenRatesMatch() {
        let x: [Float] = [0, 0.5, -0.5, 1, -1]
        XCTAssertEqual(BasicPitchTranscriber.resample(x, from: 22050, to: 22050), x)
    }

    func testResampleHalvesLengthOnDownsample() {
        let x = [Float](repeating: 0.1, count: 4410)   // 0.1s @ 44100
        let y = BasicPitchTranscriber.resample(x, from: 44100, to: 22050)
        XCTAssertEqual(y.count, 2205, accuracy: 1)      // ~0.1s @ 22050
    }

    func testResampleInterpolatesMidpoint() {
        // Upsampling a 2-sample ramp 2x should place an interpolated value between the ends.
        let y = BasicPitchTranscriber.resample([0, 1], from: 11025, to: 22050)
        XCTAssertGreaterThan(y.count, 2)
        XCTAssertTrue(y.allSatisfy { $0 >= 0 && $0 <= 1 })
    }

    // MARK: - Pure: note decoder (the ported algorithm)

    /// A single sustained, onset-marked activation in one frequency bin should decode to exactly
    /// one note at that bin, starting at the onset frame.
    func testDecoderExtractsSingleSustainedNote() {
        let nFrames = 60, nFreq = 88
        let bin = 48                       // MIDI 48 + 21 = 69 (A4)
        var frames = [[Double]](repeating: [Double](repeating: 0, count: nFreq), count: nFrames)
        var onsets = [[Double]](repeating: [Double](repeating: 0, count: nFreq), count: nFrames)
        // Strong onset peak at frame 10, sustained frame activation 10..<45.
        onsets[10][bin] = 0.95
        for t in 10..<45 { frames[t][bin] = 0.8 }

        let notes = BasicPitchDecoder.outputToNotes(
            frames: frames, onsets: onsets, onsetThresh: 0.5, frameThresh: 0.3, minNoteLen: 5)

        XCTAssertFalse(notes.isEmpty, "expected at least one decoded note")
        let main = notes.max(by: { ($0.endFrame - $0.startFrame) < ($1.endFrame - $1.startFrame) })!
        XCTAssertEqual(main.freqIdx, bin)
        XCTAssertEqual(main.startFrame, 10)
        XCTAssertGreaterThan(main.endFrame, main.startFrame + 5)
        XCTAssertGreaterThan(main.amplitude, 0.3)
    }

    func testDecoderDropsTooShortNotes() {
        let nFrames = 40, nFreq = 88, bin = 30
        var frames = [[Double]](repeating: [Double](repeating: 0, count: nFreq), count: nFrames)
        var onsets = [[Double]](repeating: [Double](repeating: 0, count: nFreq), count: nFrames)
        onsets[10][bin] = 0.9
        for t in 10..<13 { frames[t][bin] = 0.8 }   // only 3 frames long
        let notes = BasicPitchDecoder.outputToNotes(
            frames: frames, onsets: onsets, onsetThresh: 0.5, frameThresh: 0.3, minNoteLen: 11)
        XCTAssertTrue(notes.allSatisfy { $0.freqIdx != bin || ($0.endFrame - $0.startFrame) > 11 },
                      "notes shorter than minNoteLen must be dropped")
    }

    func testDecoderDeterministicOnSameInput() {
        let nFrames = 80, nFreq = 88
        var frames = [[Double]](repeating: [Double](repeating: 0, count: nFreq), count: nFrames)
        var onsets = [[Double]](repeating: [Double](repeating: 0, count: nFreq), count: nFrames)
        for (bin, t0) in [(40, 5), (52, 20), (40, 50)] {
            onsets[t0][bin] = 0.9
            for t in t0..<(t0 + 25) where t < nFrames { frames[t][bin] = 0.7 }
        }
        let a = BasicPitchDecoder.outputToNotes(frames: frames, onsets: onsets, onsetThresh: 0.5, frameThresh: 0.3, minNoteLen: 5)
        let b = BasicPitchDecoder.outputToNotes(frames: frames, onsets: onsets, onsetThresh: 0.5, frameThresh: 0.3, minNoteLen: 5)
        XCTAssertEqual(a, b, "decoder must be deterministic on identical input")
    }

    // MARK: - Pure: the indexed melodia trick must reproduce the full-grid scan, ties included
    //
    // 2026-08-26, Chris's 13:48 take: the note decode was superlinear. The fix replaces the
    // per-candidate F × P argmax rescan with `BasicPitchDecoder.FrameMaxIndex`; the contract is
    // that the (frame, pitch) sequence — and therefore every note — is unchanged, INCLUDING on
    // exact float ties, which `np.argmax` (and the shipped scan) resolve to the lowest frame,
    // then the lowest pitch. `outputToNotesReferenceScan` is the pre-0.1.16 decode kept under
    // DEBUG as the oracle.

    /// The index alone: equal maxima resolve to the lowest frame, and within a frame to the
    /// lowest pitch; after a refresh that zeroes the winner, the next-lowest tie wins.
    func testFrameMaxIndexBreaksTiesByLowestFrameThenLowestPitch() {
        let nFrames = 37, nFreq = 88   // not a power of two: exercises the padding leaves
        var grid = [[Double]](repeating: [Double](repeating: 0.1, count: nFreq), count: nFrames)
        grid[20][30] = 0.9
        grid[20][10] = 0.9    // same frame, lower pitch: must win within the frame
        grid[5][60] = 0.9     // lower frame: must win overall
        grid[36][0] = 0.9     // last frame, ties too
        var index = BasicPitchDecoder.FrameMaxIndex(grid)
        XCTAssertEqual(index.best.frame, 5)
        XCTAssertEqual(index.best.value, 0.9)
        XCTAssertEqual(index.pitch(of: 5), 60)
        XCTAssertEqual(index.pitch(of: 20), 10)

        grid[5][60] = 0
        index.refresh(frames: 5 ..< 6, in: grid, changedPitches: 59 ... 61)
        XCTAssertEqual(index.best.frame, 20)
        XCTAssertEqual(index.pitch(of: 20), 10)

        grid[20][10] = 0
        index.refresh(frames: 20 ..< 21, in: grid, changedPitches: 9 ... 11)
        XCTAssertEqual(index.best.frame, 20, "pitch 30 still holds 0.9 in frame 20")
        XCTAssertEqual(index.pitch(of: 20), 30)

        grid[20][30] = 0
        index.refresh(frames: 20 ..< 21, in: grid, changedPitches: 29 ... 31)
        XCTAssertEqual(index.best.frame, 36)
        XCTAssertEqual(index.pitch(of: 36), 0)

        // A refresh over a frame whose argmax pitch is outside the changed band is a no-op by
        // construction (its maximum cell did not change), so the answer must not move.
        grid[36][50] = 0
        index.refresh(frames: 36 ..< 37, in: grid, changedPitches: 49 ... 51)
        XCTAssertEqual(index.best.frame, 36)
        XCTAssertEqual(index.best.value, 0.9)
    }

    /// Deliberate ties everywhere the scan could resolve them differently from a naive heap:
    /// plateaus of equal energy, equal peaks in the same frame, equal peaks in adjacent pitches
    /// (so the ±1-semitone zeroing of one erases the other), equal peaks in far frames, and
    /// cells sitting EXACTLY on `frameThresh` (which is `>` to start a note but `<` to end one).
    /// No onsets, so every note comes from the melodia trick.
    func testIndexedMelodiaDecodeMatchesReferenceScanOnDeliberateTies() {
        let nFrames = 400, nFreq = 88
        var frames = [[Double]](repeating: [Double](repeating: 0, count: nFreq), count: nFrames)
        let onsets = frames
        func plateau(_ t0: Int, _ t1: Int, _ f: Int, _ v: Double) {
            for t in t0 ..< t1 where t < nFrames { frames[t][f] = v }
        }
        plateau(10, 60, 40, 0.8)      // a note
        plateau(10, 60, 41, 0.8)      // an equal note one semitone up: the first one's zeroing eats it
        plateau(30, 90, 39, 0.8)      // equal, one semitone down, overlapping
        plateau(100, 140, 20, 0.8)    // equal, far away: frame order decides
        plateau(100, 140, 70, 0.8)    // equal, same frames, higher pitch
        plateau(150, 155, 50, 0.95)   // too short to keep, still consumes energy
        plateau(200, 260, 30, 0.3)    // exactly the threshold: never starts, but does not end
        plateau(210, 215, 30, 0.31)   // one hair above: starts here, extends over the 0.3 plateau
        plateau(300, 340, 60, 0.6)
        plateau(305, 335, 61, 0.6)
        plateau(310, 330, 62, 0.6)
        plateau(350, 399, 87, 0.7)    // top edge pitch (no f+1 neighbour)
        plateau(350, 399, 0, 0.7)     // bottom edge pitch (no f-1 neighbour)
        frames[0][5] = 0.99           // frame 0: the backward pass never reaches it
        frames[nFrames - 1][5] = 0.99 // last frame: the forward pass never reaches it

        let a = BasicPitchDecoder.outputToNotes(frames: frames, onsets: onsets,
                                                onsetThresh: 0.5, frameThresh: 0.3, minNoteLen: 5)
        let b = BasicPitchDecoder.outputToNotesReferenceScan(frames: frames, onsets: onsets,
                                                             onsetThresh: 0.5, frameThresh: 0.3, minNoteLen: 5)
        XCTAssertEqual(a, b, "indexed decode diverged from the full-grid scan on a tie grid")
        XCTAssertGreaterThanOrEqual(a.count, 6, "the tie grid should yield several notes: got \(a.count)")
    }

    /// Dense, quantised random grids (values on a 1/8 lattice, so ties are the norm) with random
    /// onsets, across several seeds; this drives the refresh path through thousands of touched
    /// frames. Deterministic generator so a failure is reproducible.
    func testIndexedMelodiaDecodeMatchesReferenceScanOnQuantizedRandomGrids() {
        struct SplitMix64 {
            var state: UInt64
            mutating func next() -> UInt64 {
                state &+= 0x9E37_79B9_7F4A_7C15
                var z = state
                z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
                z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
                return z ^ (z >> 31)
            }
            mutating func unit() -> Double { Double(next() >> 11) / Double(1 << 53) }
        }
        let nFrames = 300, nFreq = 88
        var totalNotes = 0
        for seed in 1 ... 6 {
            var rng = SplitMix64(state: UInt64(seed) &* 0x1234_5678_9ABC_DEF1)
            var frames = [[Double]](repeating: [Double](repeating: 0, count: nFreq), count: nFrames)
            var onsets = frames
            for t in 0 ..< nFrames {
                for f in 0 ..< nFreq {
                    // Mostly quiet, with sustained runs so notes form; quantised to 1/8 steps.
                    let u = rng.unit()
                    frames[t][f] = u < 0.7 ? 0 : (Double(Int(rng.unit() * 8)) / 8.0)
                    onsets[t][f] = rng.unit() < 0.02 ? Double(Int(rng.unit() * 8)) / 8.0 : 0
                }
            }
            // Smear values along time so plateaus (and equal-valued neighbours) are common.
            for t in 1 ..< nFrames {
                for f in 0 ..< nFreq where frames[t][f] == 0 && rng.unit() < 0.6 {
                    frames[t][f] = frames[t - 1][f]
                }
            }
            let a = BasicPitchDecoder.outputToNotes(frames: frames, onsets: onsets,
                                                    onsetThresh: 0.5, frameThresh: 0.3, minNoteLen: 3)
            let b = BasicPitchDecoder.outputToNotesReferenceScan(frames: frames, onsets: onsets,
                                                                 onsetThresh: 0.5, frameThresh: 0.3, minNoteLen: 3)
            XCTAssertEqual(a, b, "seed \(seed): indexed decode diverged from the full-grid scan")
            totalNotes += a.count
        }
        XCTAssertGreaterThan(totalNotes, 50, "the random grids should be note-rich: got \(totalNotes)")
    }

    // MARK: - Model-dependent (skip if Core ML model load unavailable under the runner)

    private func makeTranscriberOrSkip() throws -> BasicPitchTranscriber {
        do {
            return try BasicPitchTranscriber()
        } catch {
            throw XCTSkip("Bundled Core ML model could not be loaded under this test runner "
                + "(\(error)). Model-dependent tests run via Xcode / on device — the authoritative "
                + "validation.")
        }
    }

    func testModelLoads() throws {
        _ = try makeTranscriberOrSkip()
    }

    func testInferenceProducesNotes() throws {
        let t = try makeTranscriberOrSkip()
        let audio = Self.sine(freq: 440, seconds: 2.5, sampleRate: 22050)   // A4
        let out = try t.transcribe(audio, sampleRate: 22050)
        XCTAssertFalse(out.notes.isEmpty, "expected a non-empty note list from a clear monophonic tone")
        XCTAssertGreaterThan(out.duration, 2.0)
        // Sanity (not an accuracy gate): a detected note should be near A4 (MIDI 69).
        if let nearest = out.notes.min(by: { abs($0.pitchMIDI - 69) < abs($1.pitchMIDI - 69) }) {
            XCTAssertLessThanOrEqual(abs(nearest.pitchMIDI - 69), 2, "nearest note should be within 2 semitones of A4")
        }
    }

    func testInferenceIsDeterministic() throws {
        let t = try makeTranscriberOrSkip()
        let audio = Self.sine(freq: 330, seconds: 2.0, sampleRate: 22050)
        let a = try t.transcribe(audio, sampleRate: 22050)
        let b = try t.transcribe(audio, sampleRate: 22050)
        XCTAssertEqual(a.notes, b.notes, "note output must be byte-identical across runs")
        XCTAssertEqual(a.contour, b.contour, "contour output must be byte-identical across runs")
    }

    func testEmptyBufferProducesEmptyTranscription() throws {
        let t = try makeTranscriberOrSkip()
        let out = try t.transcribe([], sampleRate: 44100)
        XCTAssertTrue(out.notes.isEmpty)
        XCTAssertTrue(out.contour.isEmpty)
        XCTAssertEqual(out.duration, 0)
    }

    // MARK: - Seam test (proves the overlapping-window fix)

    /// A sustained tone LONGER than one window (≥5 s → multiple overlapping windows) must decode to
    /// a continuous note that SPANS window boundaries — not one fragment per window — and must not
    /// place a spurious onset at a window seam. Before overlapping windows + edge trimming, the
    /// model's per-window edge degradation produced an activation dip at each seam that split the
    /// note and could inject a boundary onset. This is the test that proves the fix.
    func testLongToneIsContinuousAcrossWindowSeams() throws {
        let t = try makeTranscriberOrSkip()
        let sr = 22050.0
        let seconds = 5.0
        let audio = Self.sine(freq: 440, seconds: seconds, sampleRate: sr)   // A4, > 1 window
        let out = try t.transcribe(audio, sampleRate: sr)
        XCTAssertFalse(out.notes.isEmpty, "expected at least one note from a long steady tone")

        // Unwrapped windows tile every framesKeptPerWindow frames; seams (seconds) are multiples of
        // that — ≈1.649 s apart. A note longer than that spacing necessarily crosses a seam.
        let spf = BasicPitchTranscriber.Constants.secondsPerFrame
        let seamSpacing = Double(BasicPitchTranscriber.Constants.framesKeptPerWindow) * spf  // ≈1.649 s
        let nWindows = Int((seconds * sr / Double(BasicPitchTranscriber.Constants.hopSize)).rounded(.up))

        // (1) NOT one-fragment-per-window. Count only substantial notes (≥0.3 s) so tiny strays
        // don't mask the test; a fragmented tone would yield one ~window-length note per window.
        let substantial = out.notes.filter { $0.duration >= 0.3 }
        XCTAssertLessThanOrEqual(substantial.count, max(1, nWindows - 1),
            "long steady tone fragmented into ~one note per window: \(substantial.count) substantial notes, \(nWindows) windows")

        // (2) A single continuous note spans a seam: the longest note exceeds the seam spacing
        // (so it crosses ≥1 window boundary) and covers a majority of the signal.
        let longest = out.notes.map(\.duration).max() ?? 0
        XCTAssertGreaterThan(longest, seamSpacing,
            "longest note \(longest)s did not exceed the \(seamSpacing)s window-seam spacing — not spanning seams")
        XCTAssertGreaterThan(longest, 0.5 * seconds,
            "longest note \(longest)s covers <50% of the \(seconds)s tone — likely seam-fragmented")

        // (3) No spurious onset clustered at an interior window seam (a note legitimately starting
        // near t=0 is exempt). Allow ±2 frames around each seam time.
        let tol = 2.0 * spf
        for k in 1..<nWindows {
            let seam = Double(k) * seamSpacing
            let offending = out.notes.filter { $0.onsetTime > 0.1 && abs($0.onsetTime - seam) <= tol }
            XCTAssertTrue(offending.isEmpty,
                "spurious onset(s) at window seam \(seam)s: \(offending.map(\.onsetTime))")
        }
    }

    /// Alignment regression: overlapping windows must not shift timing. The front-pad and the first
    /// window's leading edge-trim cancel, so first-window onsets are unchanged. A 440 Hz tone after
    /// 0.5 s of silence should be detected with an onset near 0.5 s.
    func testOnsetTimeAlignmentInFirstWindow() throws {
        let t = try makeTranscriberOrSkip()
        let sr = 22050.0
        let silence = [Float](repeating: 0, count: Int(0.5 * sr))
        let tone = Self.sine(freq: 440, seconds: 1.0, sampleRate: sr)
        let out = try t.transcribe(silence + tone, sampleRate: sr)
        guard let a4 = out.notes.filter({ abs($0.pitchMIDI - 69) <= 1 }).min(by: { $0.onsetTime < $1.onsetTime }) else {
            return XCTFail("expected an A4-ish note for the 440 Hz tone")
        }
        XCTAssertEqual(a4.onsetTime, 0.5, accuracy: 0.12,
            "onset of a tone starting at 0.5 s should be ~0.5 s (alignment preserved), got \(a4.onsetTime)")
    }

    // MARK: - Helpers

    private static func sine(freq: Double, seconds: Double, sampleRate: Double) -> [Float] {
        let n = Int(seconds * sampleRate)
        return (0..<n).map { Float(0.6 * sin(2.0 * Double.pi * freq * Double($0) / sampleRate)) }
    }
}
