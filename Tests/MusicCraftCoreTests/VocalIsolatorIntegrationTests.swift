import AVFoundation
import XCTest
@testable import MusicCraftCore

/// Real-render integration test for `VocalIsolator`. The AU (`aufx`/`vois`/`appl`) is present on macOS
/// as well as iOS, so this runs on a development Mac — but it is environment-gated so the normal suite
/// stays fast and AU-free:
///
///   MCC_ISOLATION_AUDIO_FILE          — a recording that CONTAINS SINGING (wav/m4a/mp3/...).
///   MCC_ISOLATION_INSTRUMENTAL_END    — optional; end (seconds, from 0) of a leading region known to
///                                       have NO singing in it. Default 10.
///
/// Verified locally 2026-08-08 with:
///   MCC_ISOLATION_AUDIO_FILE="/Users/chris/Documents/Code/TMP/6 Human.wav" \
///   swift test --filter VocalIsolatorIntegrationTests
/// "6 Human" is 278.8 s at 48 kHz stereo and its first sung word lands at 13.84 s (WhisperBench
/// transcript, 2026-08-07), so its first 10 s is a genuinely instrumental region.
///
/// **What makes this a real test rather than a smoke test.** A pass-through AU would satisfy
/// "output exists and is the right length". The energy assertion is what proves separation actually
/// happened: the stem must lose far more energy in the instrumental region than it loses over the take
/// as a whole. Measured on device (iPhone 17 Pro Max, 2026-08-08): stem/source RMS is 0.538 over the
/// whole file but 0.0885 over the instrumental first 10 s — a 6x deeper drop where nobody is singing.
final class VocalIsolatorIntegrationTests: XCTestCase {

    /// Renders the source in its NATIVE layout (stereo for "6 Human") through the buffer API and
    /// checks length, alignment and the instrumental energy drop.
    func testIsolatesVoiceFromRealAudioThroughTheBufferAPI() async throws {
        let (url, instrumentalEnd) = try Self.environment()

        // Off the main thread on purpose: `instantiateEffect` bridges an asynchronous callback with a
        // semaphore, and the type's contract is that it is never called on the main thread.
        let report = try await Task.detached(priority: .userInitiated) { () throws -> Report in
            let source = try Self.readBuffer(url)
            let sampleRate = source.format.sampleRate
            let sourceFrames = Int(source.frameLength)

            let clock = ContinuousClock.now
            let isolated = try VocalIsolator.isolateVoice(source)
            let elapsed = (ContinuousClock.now - clock) / .seconds(1)

            return Report(
                sampleRate: sampleRate,
                channels: Int(source.format.channelCount),
                sourceFrames: sourceFrames,
                isolatedFrames: Int(isolated.frameLength),
                seconds: elapsed,
                whole: Self.rms(isolated, from: 0, to: sourceFrames) / max(1e-12, Self.rms(source, from: 0, to: sourceFrames)),
                instrumental: Self.ratio(isolated, source, upTo: instrumentalEnd, sampleRate: sampleRate),
                peak: Self.peak(isolated)
            )
        }.value

        Self.assert(report, label: "buffer API (\(report.channels) ch)")
    }

    /// Renders the same audio DOWNMIXED TO MONO through the `[Float]` API — the shape `AudioExtractor`
    /// actually consumes, and the configuration whose AU latency measured 4440 frames rather than 6360.
    func testIsolatesVoiceFromRealAudioThroughTheSampleArrayAPI() async throws {
        let (url, instrumentalEnd) = try Self.environment()

        let report = try await Task.detached(priority: .userInitiated) { () throws -> Report in
            let (samples, sampleRate) = try Self.readMono(url)

            let clock = ContinuousClock.now
            let isolated = try VocalIsolator.isolateVoice(samples, sampleRate: sampleRate)
            let elapsed = (ContinuousClock.now - clock) / .seconds(1)

            let head = min(Int(instrumentalEnd * sampleRate), min(samples.count, isolated.count))
            let wholeSource = Self.rms(samples, upTo: samples.count)
            let wholeStem = Self.rms(isolated, upTo: isolated.count)
            let headSource = Self.rms(samples, upTo: head)
            let headStem = Self.rms(isolated, upTo: head)

            return Report(
                sampleRate: sampleRate,
                channels: 1,
                sourceFrames: samples.count,
                isolatedFrames: isolated.count,
                seconds: elapsed,
                whole: wholeStem / max(1e-12, wholeSource),
                instrumental: headStem / max(1e-12, headSource),
                peak: isolated.reduce(0) { Swift.max($0, abs($1)) }
            )
        }.value

        Self.assert(report, label: "sample-array API (mono)")
    }

    /// Seconds of audio the extractor test analyses.
    ///
    /// Isolation is cheap; Basic Pitch in an UNOPTIMIZED test build is not — `BasicPitchDecoder`'s
    /// per-frame argmax over 264 bins costs minutes of CPU on a 4.6-minute take, and this test runs
    /// two full passes. 45 s keeps the test honest and quick: on "6 Human" it spans the instrumental
    /// intro AND real singing (first sung word at 13.84 s, WhisperBench transcript 2026-08-07).
    static let extractorWindowSeconds: Double = 45

    /// The other half of the feature, end to end: a real isolated signal, fed through
    /// `AudioExtractor`'s `isolatedVoice:` overload, must move the contour while leaving every
    /// mix-derived field untouched.
    func testIsolatedVoiceChangesOnlyTheContourInTheExtractor() async throws {
        let (url, _) = try Self.environment()

        let (mix, sampleRate, isolated) = try await Task.detached(priority: .userInitiated) {
            () throws -> ([Float], Double, [Float]) in
            let (full, rate) = try Self.readMono(url)
            let samples = Array(full.prefix(Int(Self.extractorWindowSeconds * rate)))
            return (samples, rate, try VocalIsolator.isolateVoice(samples, sampleRate: rate))
        }.value

        let mixOnly = AudioExtractor.extract(buffer: mix, sampleRate: sampleRate)
        let routed = AudioExtractor.extract(buffer: mix, sampleRate: sampleRate, isolatedVoice: isolated)

        XCTAssertEqual(routed.detectedNotes, mixOnly.detectedNotes, "detectedNotes must stay mix-derived")
        XCTAssertEqual(routed.key, mixOnly.key, "key must stay mix-derived")
        XCTAssertEqual(routed.voicingDensity, mixOnly.voicingDensity, accuracy: 1e-12, "voicingDensity must stay mix-derived")
        XCTAssertEqual(routed.chordSegments.count, mixOnly.chordSegments.count, "chords must stay mix-derived")

        XCTAssertFalse(routed.contour.isEmpty, "The isolated voice must yield a contour")
        XCTAssertNotEqual(routed.contour, mixOnly.contour, "The stem contour must actually differ from the mix contour")

        let mixRate = Double(mixOnly.contour.count) / mixOnly.duration
        let stemRate = Double(routed.contour.count) / routed.duration
        print("""
        AudioExtractor contour source
          mix   : \(mixOnly.contour.count) events, \(String(format: "%.2f", mixRate))/s
          stem  : \(routed.contour.count) events, \(String(format: "%.2f", stemRate))/s
        """)
        XCTAssertLessThan(stemRate, mixRate, "The isolated line should be sparser than the mix's noise")
    }

    // MARK: - Assertions

    private struct Report {
        let sampleRate: Double
        let channels: Int
        let sourceFrames: Int
        let isolatedFrames: Int
        let seconds: Double
        /// stem RMS / source RMS over the whole take.
        let whole: Double
        /// stem RMS / source RMS over the known instrumental region.
        let instrumental: Double
        let peak: Float
    }

    private static func assert(_ report: Report, label: String) {
        let duration = Double(report.sourceFrames) / report.sampleRate
        print("""
        VocalIsolator \(label)
          \(report.sourceFrames) frames in, \(report.isolatedFrames) out at \(Int(report.sampleRate)) Hz
          \(String(format: "%.2f", report.seconds)) s for \(String(format: "%.1f", duration)) s \
        (\(String(format: "%.0f", duration / max(1e-9, report.seconds)))x realtime)
          stem/source RMS: \(String(format: "%.4f", report.whole)) whole, \
        \(String(format: "%.4f", report.instrumental)) instrumental
          stem peak: \(String(format: "%.4f", report.peak))
        """)

        XCTAssertGreaterThan(report.isolatedFrames, 0, "The render produced nothing")
        // The head trim is compensated, so the output is the source length. One render block of slack
        // covers the engine running dry on the final partial block.
        XCTAssertEqual(
            Double(report.isolatedFrames), Double(report.sourceFrames),
            accuracy: Double(VocalIsolator.renderBlockFrames),
            "The isolated signal must be the same length as the source (head trim compensated)"
        )
        XCTAssertGreaterThan(report.peak, 0, "The stem is digital silence — the AU did not render")

        // THE PROOF OF SEPARATION. A pass-through would put both ratios at 1.0; a broken render would
        // put both at 0. Only real isolation loses most of the energy where nobody is singing while
        // keeping a lot of it where somebody is. Measured on device: 0.0885 instrumental vs 0.538
        // whole. The bar is set at half, well inside that 6x margin, so it tolerates a different song.
        XCTAssertLessThan(
            report.instrumental, report.whole * 0.5,
            "Energy must drop far more in the instrumental region than over the take as a whole "
            + "(instrumental \(report.instrumental), whole \(report.whole)) — otherwise nothing was separated"
        )
        XCTAssertLessThan(report.instrumental, 1.0, "The instrumental region must lose energy, not gain it")
    }

    // MARK: - Environment + audio helpers

    private static func environment() throws -> (url: URL, instrumentalEnd: Double) {
        let environment = ProcessInfo.processInfo.environment
        guard let path = environment["MCC_ISOLATION_AUDIO_FILE"] else {
            throw XCTSkip("MCC_ISOLATION_AUDIO_FILE not set — skipping the real-render isolation test.")
        }
        guard VocalIsolator.isAvailable else {
            throw XCTSkip("AUSoundIsolation is not present on this system.")
        }
        let end = environment["MCC_ISOLATION_INSTRUMENTAL_END"].flatMap(Double.init) ?? 10
        return (URL(fileURLWithPath: path), end)
    }

    /// Read a file in its native channel layout as non-interleaved Float32.
    private static func readBuffer(_ url: URL) throws -> AVAudioPCMBuffer {
        let file = try AVAudioFile(forReading: url)
        let buffer = try XCTUnwrap(
            AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))
        )
        try file.read(into: buffer)
        return buffer
    }

    /// Read a file downmixed to mono Float32 at its native rate.
    private static func readMono(_ url: URL) throws -> (samples: [Float], sampleRate: Double) {
        let buffer = try readBuffer(url)
        let channels = Int(buffer.format.channelCount)
        let frames = Int(buffer.frameLength)
        let data = try XCTUnwrap(buffer.floatChannelData)
        var mono = [Float](repeating: 0, count: frames)
        for channel in 0..<channels {
            let source = data[channel]
            for frame in 0..<frames { mono[frame] += source[frame] }
        }
        if channels > 1 {
            let scale = 1 / Float(channels)
            for frame in 0..<frames { mono[frame] *= scale }
        }
        return (mono, buffer.format.sampleRate)
    }

    private static func ratio(
        _ stem: AVAudioPCMBuffer,
        _ source: AVAudioPCMBuffer,
        upTo seconds: Double,
        sampleRate: Double
    ) -> Double {
        let frames = min(Int(seconds * sampleRate), min(Int(stem.frameLength), Int(source.frameLength)))
        let denominator = rms(source, from: 0, to: frames)
        return rms(stem, from: 0, to: frames) / max(1e-12, denominator)
    }

    private static func rms(_ buffer: AVAudioPCMBuffer, from start: Int, to end: Int) -> Double {
        guard let data = buffer.floatChannelData else { return 0 }
        let upper = min(end, Int(buffer.frameLength))
        guard upper > start else { return 0 }
        var sum = 0.0
        var count = 0
        for channel in 0..<Int(buffer.format.channelCount) {
            let samples = data[channel]
            for frame in start..<upper { sum += Double(samples[frame]) * Double(samples[frame]) }
            count += upper - start
        }
        return count > 0 ? (sum / Double(count)).squareRoot() : 0
    }

    private static func rms(_ samples: [Float], upTo count: Int) -> Double {
        let upper = min(count, samples.count)
        guard upper > 0 else { return 0 }
        var sum = 0.0
        for index in 0..<upper { sum += Double(samples[index]) * Double(samples[index]) }
        return (sum / Double(upper)).squareRoot()
    }

    private static func peak(_ buffer: AVAudioPCMBuffer) -> Float {
        guard let data = buffer.floatChannelData else { return 0 }
        var peak: Float = 0
        for channel in 0..<Int(buffer.format.channelCount) {
            let samples = data[channel]
            for frame in 0..<Int(buffer.frameLength) { peak = Swift.max(peak, abs(samples[frame])) }
        }
        return peak
    }
}
