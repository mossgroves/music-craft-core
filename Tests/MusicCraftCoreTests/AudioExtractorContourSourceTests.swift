import AVFoundation
import XCTest
@testable import MusicCraftCore

/// Tests for the 0.1.8 vocal-stem contour side-channel: the plausibility guard (pure), the contour
/// selection (pure), and the `extract` API routing.
///
/// The routing tests feed a REAL fixture as the "isolated voice" rather than rendering one, so they
/// prove the routing deterministically without depending on the AudioUnit. The AU itself is proven by
/// the environment-gated `VocalIsolatorIntegrationTests`.
final class AudioExtractorContourSourceTests: XCTestCase {

    // MARK: - Helpers

    /// `count` contour notes with arbitrary but well-formed content. Only the COUNT matters to the
    /// guard, which is the point: it judges density, never musical content.
    private func contour(count: Int) -> [ContourNote] {
        (0..<count).map { index in
            ContourNote(
                pitchSemitoneStep: index == 0 ? 0 : 1,
                parsonsCode: index == 0 ? .repeat_ : .up,
                onsetTime: TimeInterval(index) * 0.1,
                duration: 0.1
            )
        }
    }

    // MARK: - The plausibility guard (pure)

    /// An empty stem contour is the shape a failed separation takes, and it is rejected outright —
    /// there is no duration at which zero events is a melody.
    func testEmptyStemContourIsImplausible() {
        XCTAssertFalse(AudioExtractor.isPlausibleStemContour([], duration: 278.8))
        XCTAssertFalse(AudioExtractor.isPlausibleStemContour([], duration: 0.5))
    }

    /// The measured good case: "6 Human" (2026-08-08) isolated to 394 contour events over 278.8 s =
    /// 1.41 events/s, comfortably above the 0.25/s floor. If this ever fails, the guard has been
    /// tightened past the only sung line it was calibrated against.
    func testTheMeasuredSungContourIsPlausible() {
        XCTAssertTrue(AudioExtractor.isPlausibleStemContour(contour(count: 394), duration: 278.8))
    }

    /// The failure the guard exists for: a separation that produced almost nothing over a long take.
    func testAStemContourWellBelowTheFloorIsImplausible() {
        // 20 events over 278.8 s = 0.07/s.
        XCTAssertFalse(AudioExtractor.isPlausibleStemContour(contour(count: 20), duration: 278.8))
    }

    /// The floor is inclusive: exactly 0.25 events/s passes, just under it does not.
    func testTheFloorIsInclusive() {
        XCTAssertEqual(AudioExtractor.minimumStemContourNoteRate, 0.25, accuracy: 1e-12)
        XCTAssertTrue(AudioExtractor.isPlausibleStemContour(contour(count: 25), duration: 100))
        XCTAssertFalse(AudioExtractor.isPlausibleStemContour(contour(count: 24), duration: 100))
    }

    /// Short takes are judged by the same rate, which is deliberately generous: one held note per four
    /// seconds still passes, so a brief hum is not thrown away for being brief.
    func testAShortHumIsNotRejectedForBeingShort() {
        XCTAssertTrue(AudioExtractor.isPlausibleStemContour(contour(count: 1), duration: 4.0))
        XCTAssertTrue(AudioExtractor.isPlausibleStemContour(contour(count: 3), duration: 3.0))
    }

    /// A non-positive duration cannot produce a rate; reject rather than divide.
    func testNonPositiveDurationIsImplausible() {
        XCTAssertFalse(AudioExtractor.isPlausibleStemContour(contour(count: 100), duration: 0))
        XCTAssertFalse(AudioExtractor.isPlausibleStemContour(contour(count: 100), duration: -1))
    }

    /// No density CEILING: a fast sung line is not rejected for being dense. Documented as deliberate
    /// on `isPlausibleStemContour` — there is no measurement yet separating melisma from noise.
    func testADenseStemContourIsStillPlausible() {
        XCTAssertTrue(AudioExtractor.isPlausibleStemContour(contour(count: 1190), duration: 278.8))
    }

    // MARK: - Contour selection (pure)

    func testSelectContourKeepsTheMixWhenThereIsNoStem() {
        let mix = contour(count: 50)
        XCTAssertEqual(AudioExtractor.selectContour(mix: mix, stem: nil, duration: 100), mix)
    }

    func testSelectContourKeepsTheMixWhenTheStemIsImplausible() {
        let mix = contour(count: 50)
        let stem = contour(count: 2)
        XCTAssertEqual(AudioExtractor.selectContour(mix: mix, stem: stem, duration: 278.8), mix)
    }

    func testSelectContourKeepsTheMixWhenTheStemIsEmpty() {
        let mix = contour(count: 50)
        XCTAssertEqual(AudioExtractor.selectContour(mix: mix, stem: [], duration: 100), mix)
    }

    func testSelectContourTakesAPlausibleStem() {
        let mix = contour(count: 1190)
        let stem = contour(count: 394)
        XCTAssertEqual(AudioExtractor.selectContour(mix: mix, stem: stem, duration: 278.8), stem)
    }

    /// Fail-soft is symmetric: when BOTH are unusable the caller still gets the mix contour (empty),
    /// never a stem contour that failed the guard.
    func testSelectContourFallsBackToAnEmptyMixRatherThanABadStem() {
        XCTAssertEqual(AudioExtractor.selectContour(mix: [], stem: contour(count: 1), duration: 278.8), [])
    }

    // MARK: - Configuration surface

    /// The default is `.mix`: every existing caller keeps today's behavior with no code change.
    func testDefaultConfigurationTracesTheContourFromTheMix() {
        XCTAssertEqual(AudioExtractor.Configuration.default.contourSource, .mix)
        XCTAssertEqual(AudioExtractor.Configuration().contourSource, .mix)
    }

    /// Source compatibility: the pre-0.1.8 nine-argument initializer still compiles and still means
    /// `.mix`. (This is the call shape `AudioExtractorTests.testConfigurationPublicInit` uses.)
    func testThePreExistingInitializerStillMeansMix() {
        let configuration = AudioExtractor.Configuration(
            onsetMinGapMs: 500,
            onsetEnergyMultiplier: 2.0,
            onsetEnergyFloor: 0.005,
            chromaWindowSize: 8192,
            chromaHopSize: 4096,
            earlyFrameAttackSkip: 2,
            earlyFrameWindowSize: 8,
            extractionMinConfidence: 0.25,
            silenceThreshold: 0.001
        )
        XCTAssertEqual(configuration.contourSource, .mix)
        XCTAssertEqual(configuration, AudioExtractor.Configuration.default)
    }

    func testContourSourceIsAStableCaseIterableRawRepresentable() {
        XCTAssertEqual(AudioExtractor.Configuration.ContourSource.allCases, [.mix, .isolatedVoice])
        XCTAssertEqual(AudioExtractor.Configuration.ContourSource.mix.rawValue, "mix")
        XCTAssertEqual(AudioExtractor.Configuration.ContourSource.isolatedVoice.rawValue, "isolatedVoice")
    }

    /// Two configurations differing only in `contourSource` must not compare equal — the field is part
    /// of the value, not decoration.
    func testContourSourceParticipatesInEquality() {
        let mix = AudioExtractor.Configuration()
        let isolated = AudioExtractor.Configuration(contourSource: .isolatedVoice)
        XCTAssertNotEqual(mix, isolated)
        XCTAssertNotEqual(mix.hashValue, isolated.hashValue)
    }

    // MARK: - API routing (real fixtures, no AudioUnit)

    /// Passing `isolatedVoice: nil` must be byte-identical to not passing it at all — the guarantee
    /// that the new overload cannot change an existing caller's result.
    func testNilIsolatedVoiceIsIdenticalToTheThreeArgumentCall() throws {
        let (samples, sampleRate) = try Self.fixture("Am", "Am_001")

        let baseline = AudioExtractor.extract(buffer: samples, sampleRate: sampleRate)
        let routed = AudioExtractor.extract(buffer: samples, sampleRate: sampleRate, isolatedVoice: nil)

        Self.assertSameResult(routed, baseline)
    }

    /// `.mix` explicitly requested must equal the default — no hidden second path.
    func testExplicitMixConfigurationIsIdenticalToTheDefault() throws {
        let (samples, sampleRate) = try Self.fixture("Am", "Am_001")

        let baseline = AudioExtractor.extract(buffer: samples, sampleRate: sampleRate)
        let explicit = AudioExtractor.extract(
            buffer: samples,
            sampleRate: sampleRate,
            configuration: AudioExtractor.Configuration(contourSource: .mix)
        )

        Self.assertSameResult(explicit, baseline)
    }

    /// **The hard rule, under test.** With a supplied "isolated voice" that is a DIFFERENT recording
    /// from the mix, only `contour` may change: chords, key, detected notes, duration and
    /// voicingDensity must still read the mix exactly as they did before. And the contour that lands
    /// must be the one the voice buffer produces on its own — proof the second pass ran and its output
    /// is what reached the Result.
    func testASuppliedVoiceReplacesTheContourAndNothingElse() throws {
        let (mixSamples, mixRate) = try Self.fixture("Am", "Am_001")
        let (voiceSamples, voiceRate) = try Self.fixture("C", "C_001")
        XCTAssertEqual(mixRate, voiceRate, "The fixtures must share a rate; isolatedVoice is read at the mix's rate")

        let mixOnly = AudioExtractor.extract(buffer: mixSamples, sampleRate: mixRate)
        let voiceOnly = AudioExtractor.extract(buffer: voiceSamples, sampleRate: voiceRate)
        let routed = AudioExtractor.extract(buffer: mixSamples, sampleRate: mixRate, isolatedVoice: voiceSamples)

        // Everything except the contour still comes from the mix.
        XCTAssertEqual(routed.detectedNotes, mixOnly.detectedNotes, "detectedNotes must stay mix-derived")
        XCTAssertEqual(routed.key, mixOnly.key, "key must stay mix-derived")
        XCTAssertEqual(routed.voicingDensity, mixOnly.voicingDensity, accuracy: 1e-12,
                       "voicingDensity must stay mix-derived (the take-type signal the app gates on)")
        XCTAssertEqual(routed.duration, mixOnly.duration, accuracy: 1e-12)
        Self.assertSameChordSegments(routed.chordSegments, mixOnly.chordSegments)

        // The contour is the voice buffer's, not the mix's.
        XCTAssertFalse(voiceOnly.contour.isEmpty, "Fixture precondition: the voice buffer must transcribe to a contour")
        XCTAssertEqual(routed.contour, voiceOnly.contour, "The contour must come from the supplied voice buffer")
        XCTAssertNotEqual(routed.contour, mixOnly.contour, "Fixture precondition: the two fixtures must differ")
    }

    /// A silent "stem" is what a separation failure leaves behind. The mix contour must survive it,
    /// with no error — the fail-soft rule, exercised through the public API.
    func testASilentSuppliedVoiceKeepsTheMixContour() throws {
        let (samples, sampleRate) = try Self.fixture("Am", "Am_001")
        let silence = [Float](repeating: 0, count: samples.count)

        let mixOnly = AudioExtractor.extract(buffer: samples, sampleRate: sampleRate)
        let routed = AudioExtractor.extract(buffer: samples, sampleRate: sampleRate, isolatedVoice: silence)

        Self.assertSameResult(routed, mixOnly)
    }

    /// An empty "stem" is the other failure shape (the render produced nothing).
    func testAnEmptySuppliedVoiceKeepsTheMixContour() throws {
        let (samples, sampleRate) = try Self.fixture("Am", "Am_001")

        let mixOnly = AudioExtractor.extract(buffer: samples, sampleRate: sampleRate)
        let routed = AudioExtractor.extract(buffer: samples, sampleRate: sampleRate, isolatedVoice: [])

        Self.assertSameResult(routed, mixOnly)
    }

    /// The near-silence guard on the MIX short-circuits before any isolation is attempted, so asking
    /// for `.isolatedVoice` on digital silence is still an empty Result and still costs no AU render.
    func testSilentMixReturnsAnEmptyResultEvenWhenIsolationIsRequested() {
        let silence = [Float](repeating: 0, count: 44100)
        let result = AudioExtractor.extract(
            buffer: silence,
            sampleRate: 44100,
            configuration: AudioExtractor.Configuration(contourSource: .isolatedVoice)
        )

        XCTAssertTrue(result.contour.isEmpty)
        XCTAssertTrue(result.detectedNotes.isEmpty)
        XCTAssertTrue(result.chordSegments.isEmpty)
        XCTAssertNil(result.key)
        XCTAssertEqual(result.duration, 1.0, accuracy: 0.001)
    }

    // MARK: - Fixture + comparison helpers

    /// Load one bundled TaylorNylon chord fixture as mono Float32 at its native rate.
    private static func fixture(_ chord: String, _ name: String) throws -> (samples: [Float], sampleRate: Double) {
        let url = try XCTUnwrap(
            Bundle.module.url(
                forResource: name,
                withExtension: "wav",
                subdirectory: "Fixtures/real-audio/taylor-nylon/\(chord)"
            ),
            "Missing bundled fixture \(chord)/\(name).wav"
        )
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        let buffer = try XCTUnwrap(
            AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(file.length))
        )
        try file.read(into: buffer)
        let channel = try XCTUnwrap(buffer.floatChannelData?[0])
        let samples = [Float](UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
        return (samples, format.sampleRate)
    }

    /// Full-result equality that ignores `ChordSegment.id` — the ids are fresh UUIDs on every call, so
    /// `Result: Equatable` can never hold across two extractions of the same audio.
    private static func assertSameResult(
        _ actual: AudioExtractor.Result,
        _ expected: AudioExtractor.Result,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(actual.contour, expected.contour, "contour", file: file, line: line)
        XCTAssertEqual(actual.detectedNotes, expected.detectedNotes, "detectedNotes", file: file, line: line)
        XCTAssertEqual(actual.key, expected.key, "key", file: file, line: line)
        XCTAssertEqual(actual.duration, expected.duration, accuracy: 1e-12, "duration", file: file, line: line)
        XCTAssertEqual(actual.voicingDensity, expected.voicingDensity, accuracy: 1e-12, "voicingDensity", file: file, line: line)
        assertSameChordSegments(actual.chordSegments, expected.chordSegments, file: file, line: line)
    }

    private static func assertSameChordSegments(
        _ actual: [AudioExtractor.ChordSegment],
        _ expected: [AudioExtractor.ChordSegment],
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(actual.count, expected.count, "chordSegments count", file: file, line: line)
        for (lhs, rhs) in zip(actual, expected) {
            XCTAssertEqual(lhs.startTime, rhs.startTime, accuracy: 1e-12, file: file, line: line)
            XCTAssertEqual(lhs.endTime, rhs.endTime, accuracy: 1e-12, file: file, line: line)
            XCTAssertEqual(lhs.chord, rhs.chord, file: file, line: line)
            XCTAssertEqual(lhs.confidence, rhs.confidence, accuracy: 1e-12, file: file, line: line)
            XCTAssertEqual(lhs.detectionMethod, rhs.detectionMethod, file: file, line: line)
        }
    }
}
