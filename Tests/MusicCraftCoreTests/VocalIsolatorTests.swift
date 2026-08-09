import AVFoundation
import XCTest
@testable import MusicCraftCore

/// Pure-logic tests for `VocalIsolator`: the latency-trim arithmetic, the channel-support reading,
/// and every failure path that can be reached WITHOUT instantiating the AudioUnit.
///
/// Deliberately AU-free so they run identically on any machine and in CI. The real render is proven
/// by `VocalIsolatorIntegrationTests`, which is environment-gated.
final class VocalIsolatorTests: XCTestCase {

    // MARK: - Latency trim arithmetic

    /// The measured stereo case: the AU reported 0.1325 s at 48 kHz on device 2026-08-08, which is
    /// exactly the 6360 frames the harness recorded. This test is the arithmetic half of the
    /// alignment guarantee — if it drifts, derived timings drift with it.
    func testHeadTrimFramesMatchesTheMeasuredStereoLatency() {
        XCTAssertEqual(VocalIsolator.headTrimFrames(latencySeconds: 0.1325, sampleRate: 48000), 6360)
    }

    /// The measured mono case: 4440 frames at 48 kHz (0.0925 s).
    func testHeadTrimFramesMatchesTheMeasuredMonoLatency() {
        XCTAssertEqual(VocalIsolator.headTrimFrames(latencySeconds: 0.0925, sampleRate: 48000), 4440)
    }

    /// Frames are rounded, not truncated: 0.1325 s × 44100 = 5843.25.
    func testHeadTrimFramesRoundsToNearestFrame() {
        XCTAssertEqual(VocalIsolator.headTrimFrames(latencySeconds: 0.1325, sampleRate: 44100), 5843)
        // 0.5 rounds away from zero, matching Double.rounded()'s default rule.
        XCTAssertEqual(VocalIsolator.headTrimFrames(latencySeconds: 0.5, sampleRate: 3), 2)
    }

    /// A broken latency report must trim NOTHING rather than corrupt the alignment or eat the take.
    func testHeadTrimFramesRefusesNonsenseLatency() {
        XCTAssertEqual(VocalIsolator.headTrimFrames(latencySeconds: 0, sampleRate: 48000), 0)
        XCTAssertEqual(VocalIsolator.headTrimFrames(latencySeconds: -0.1325, sampleRate: 48000), 0)
        XCTAssertEqual(VocalIsolator.headTrimFrames(latencySeconds: .nan, sampleRate: 48000), 0)
        XCTAssertEqual(VocalIsolator.headTrimFrames(latencySeconds: .infinity, sampleRate: 48000), 0)
    }

    func testHeadTrimFramesRefusesNonsenseSampleRate() {
        XCTAssertEqual(VocalIsolator.headTrimFrames(latencySeconds: 0.1325, sampleRate: 0), 0)
        XCTAssertEqual(VocalIsolator.headTrimFrames(latencySeconds: 0.1325, sampleRate: -48000), 0)
        XCTAssertEqual(VocalIsolator.headTrimFrames(latencySeconds: 0.1325, sampleRate: .nan), 0)
    }

    /// The whole point of the head trim: pull the take PLUS the latency so that, after dropping the
    /// latency, the output is the same length as the source.
    func testTotalFramesToRenderAddsTheHead() {
        XCTAssertEqual(VocalIsolator.totalFramesToRender(sourceFrames: 13_382_400, headTrimFrames: 6360), 13_388_760)
        XCTAssertEqual(VocalIsolator.totalFramesToRender(sourceFrames: 1000, headTrimFrames: 0), 1000)
    }

    func testTotalFramesToRenderClampsNegatives() {
        XCTAssertEqual(VocalIsolator.totalFramesToRender(sourceFrames: -5, headTrimFrames: -5), 0)
        XCTAssertEqual(VocalIsolator.totalFramesToRender(sourceFrames: 100, headTrimFrames: -5), 100)
    }

    /// The trim almost never lands on a block boundary, which is the only reason the split exists.
    func testHeadTrimSplitStraddlesABlockBoundary() {
        let split = VocalIsolator.headTrimSplit(producedFrames: 4096, remainingTrim: 2264)
        XCTAssertEqual(split.skip, 2264)
        XCTAssertEqual(split.keep, 1832)
    }

    func testHeadTrimSplitConsumesTheWholeBlockWhenTrimExceedsIt() {
        let split = VocalIsolator.headTrimSplit(producedFrames: 4096, remainingTrim: 6360)
        XCTAssertEqual(split.skip, 4096)
        XCTAssertEqual(split.keep, 0)
    }

    func testHeadTrimSplitKeepsEverythingOnceTheTrimIsSpent() {
        let split = VocalIsolator.headTrimSplit(producedFrames: 4096, remainingTrim: 0)
        XCTAssertEqual(split.skip, 0)
        XCTAssertEqual(split.keep, 4096)
    }

    func testHeadTrimSplitHandlesAnEmptyBlock() {
        let split = VocalIsolator.headTrimSplit(producedFrames: 0, remainingTrim: 6360)
        XCTAssertEqual(split.skip, 0)
        XCTAssertEqual(split.keep, 0)
    }

    /// Conservation, walked over a whole render the way the loop does it: with the measured 6360-frame
    /// stereo trim and 4096-frame blocks, the frames that reach the output must add up to exactly the
    /// source length. This is the property the per-block split exists to guarantee.
    func testHeadTrimSplitConservesTheSourceLengthAcrossBlocks() {
        let sourceFrames = 13_382_400          // "6 Human", 278.8 s at 48 kHz
        let trim = 6360                        // the AU's measured stereo latency
        let block = Int(VocalIsolator.renderBlockFrames)

        let total = VocalIsolator.totalFramesToRender(sourceFrames: sourceFrames, headTrimFrames: trim)
        var rendered = 0
        var remainingTrim = trim
        var kept = 0
        while rendered < total {
            let produced = min(block, total - rendered)
            rendered += produced
            let split = VocalIsolator.headTrimSplit(producedFrames: produced, remainingTrim: remainingTrim)
            remainingTrim -= split.skip
            kept += split.keep
        }

        XCTAssertEqual(kept, sourceFrames, "The trimmed render must be exactly as long as the source")
        XCTAssertEqual(remainingTrim, 0, "The whole latency head must be consumed")
    }

    // MARK: - Channel support

    /// By AU convention, NOT publishing `kAudioUnitProperty_SupportedNumChannels` means the unit takes
    /// anything. Refusing everything in that case would make the guard the failure.
    func testChannelSupportWithNoPublishedPropertyAcceptsAnything() {
        let support = VocalIsolator.ChannelSupport(pairs: [])
        XCTAssertTrue(support.accepts(1))
        XCTAssertTrue(support.accepts(2))
        XCTAssertTrue(support.accepts(6))
        XCTAssertEqual(support.descriptions, ["any layout (the AU does not publish the property)"])
    }

    /// A negative entry is the AU's wildcard. This is what the AU actually reports on device
    /// ("any in / any out", measured 2026-08-08).
    func testChannelSupportWildcardEntryAcceptsAnything() {
        let support = VocalIsolator.ChannelSupport(pairs: [(-1, -1)])
        XCTAssertTrue(support.accepts(1))
        XCTAssertTrue(support.accepts(2))
        XCTAssertEqual(support.descriptions, ["any in / any out"])
    }

    func testChannelSupportExactPairsAcceptOnlyThoseLayouts() {
        let support = VocalIsolator.ChannelSupport(pairs: [(1, 1), (2, 2)])
        XCTAssertTrue(support.accepts(1))
        XCTAssertTrue(support.accepts(2))
        XCTAssertFalse(support.accepts(3))
        XCTAssertEqual(support.descriptions, ["1 in / 1 out", "2 in / 2 out"])
    }

    /// A pair whose input and output differ (e.g. a downmixer) must not accept a count that only
    /// matches one side.
    func testChannelSupportAsymmetricPairIsNotHalfAccepted() {
        let support = VocalIsolator.ChannelSupport(pairs: [(2, 1)])
        XCTAssertFalse(support.accepts(1))
        XCTAssertFalse(support.accepts(2))
    }

    // MARK: - Failure paths reachable without the AudioUnit

    func testEmptySampleArrayThrowsEmptyInput() {
        XCTAssertThrowsError(try VocalIsolator.isolateVoice([], sampleRate: 48000)) { error in
            XCTAssertEqual(error as? VocalIsolator.Failure, .emptyInput)
        }
    }

    func testNonsenseSampleRateThrowsBeforeTouchingTheAudioUnit() {
        for rate in [0.0, -48000.0, Double.nan] {
            XCTAssertThrowsError(try VocalIsolator.isolateVoice([0.1, 0.2, 0.3], sampleRate: rate)) { error in
                guard case .invalidSampleRate = (error as? VocalIsolator.Failure) else {
                    return XCTFail("Expected .invalidSampleRate for \(rate), got \(error)")
                }
            }
        }
    }

    func testEmptyBufferThrowsEmptyInput() throws {
        let format = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48000, channels: 1, interleaved: false))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 128))
        buffer.frameLength = 0
        XCTAssertThrowsError(try VocalIsolator.isolateVoice(buffer)) { error in
            XCTAssertEqual(error as? VocalIsolator.Failure, .emptyInput)
        }
    }

    func testInterleavedBufferThrowsUnsupportedFormat() throws {
        let format = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48000, channels: 2, interleaved: true))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 128))
        buffer.frameLength = 128
        XCTAssertThrowsError(try VocalIsolator.isolateVoice(buffer)) { error in
            guard case .unsupportedFormat = (error as? VocalIsolator.Failure) else {
                return XCTFail("Expected .unsupportedFormat, got \(error)")
            }
        }
    }

    func testIntegerBufferThrowsUnsupportedFormat() throws {
        let format = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 48000, channels: 1, interleaved: false))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 128))
        buffer.frameLength = 128
        XCTAssertThrowsError(try VocalIsolator.isolateVoice(buffer)) { error in
            guard case .unsupportedFormat = (error as? VocalIsolator.Failure) else {
                return XCTFail("Expected .unsupportedFormat, got \(error)")
            }
        }
    }

    /// Mono and stereo only. Checked before the AU is asked anything, so a surround take fails fast
    /// and legibly instead of being refused deep inside the engine.
    func testMultichannelBufferThrowsUnsupportedChannelCount() throws {
        // AVAudioFormat's channel-count initializer only vends mono/stereo, so a 5.1 layout has to be
        // built explicitly to reach the guard at all.
        let layout = try XCTUnwrap(AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_MPEG_5_1_D))
        let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channelLayout: layout)
        XCTAssertEqual(format.channelCount, 6)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 128))
        buffer.frameLength = 128
        XCTAssertThrowsError(try VocalIsolator.isolateVoice(buffer)) { error in
            XCTAssertEqual(error as? VocalIsolator.Failure, .unsupportedChannelCount(6))
        }
    }

    /// Every failure carries a description, because the consuming app logs them even though it never
    /// shows them to a songwriter (hard rule: fail soft, no user-visible error).
    func testEveryFailureCarriesADescription() {
        let failures: [VocalIsolator.Failure] = [
            .componentUnavailable,
            .instantiationFailed("boom"),
            .emptyInput,
            .invalidSampleRate(0),
            .unsupportedFormat("int16"),
            .unsupportedChannelCount(6),
            .channelCountRefused(2, "1 in / 1 out"),
            .renderFailed("boom"),
            .cancelled,
        ]
        for failure in failures {
            XCTAssertFalse(failure.errorDescription?.isEmpty ?? true, "\(failure) needs a description")
        }
    }

    /// The availability probe is a pure component-manager question: it must answer without throwing
    /// or trapping wherever the suite runs, including where the AU is absent.
    func testAvailabilityQueryAnswersWithoutTrapping() {
        _ = VocalIsolator.isAvailable
    }
}
