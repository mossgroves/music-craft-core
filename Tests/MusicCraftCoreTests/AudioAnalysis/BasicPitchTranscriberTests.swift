import XCTest
@testable import MusicCraftCore

/// Phase 1 tests for `BasicPitchTranscriber` (MCC 0.0.14, `specs/0.0.14-basic-pitch-adoption.md`).
///
/// Two tiers:
///  - **Pure** (always run on the CLI): the vDSP resampler and the ported note decoder.
///    These validate the adapted algorithm without Core ML.
///  - **Model-dependent** (load + run the bundled Core ML model): these `XCTSkip` if Core ML
///    model loading isn't available under the test runner, rather than fail — the authoritative
///    model validation is the device/Xcode step gating the 0.0.14 tag.
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

    // MARK: - Model-dependent (skip if Core ML model load unavailable under the runner)

    private func makeTranscriberOrSkip() throws -> BasicPitchTranscriber {
        do {
            return try BasicPitchTranscriber()
        } catch {
            throw XCTSkip("Bundled Core ML model could not be loaded under this test runner "
                + "(\(error)). Model-dependent tests run via Xcode / on device — the authoritative "
                + "validation gating the 0.0.14 tag.")
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

    // MARK: - Helpers

    private static func sine(freq: Double, seconds: Double, sampleRate: Double) -> [Float] {
        let n = Int(seconds * sampleRate)
        return (0..<n).map { Float(0.6 * sin(2.0 * Double.pi * freq * Double($0) / sampleRate)) }
    }
}
