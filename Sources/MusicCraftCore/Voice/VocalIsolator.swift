import AVFoundation
import AudioToolbox
import Foundation

/// Offline vocal isolation through Apple's **AUSoundIsolation** AudioUnit (`aufx`/`vois`/`appl`).
///
/// **What it does.** Renders a mono or stereo Float32 buffer through the AU in
/// `AVAudioEngine.manualRenderingMode(.offline)`, fully wet, isolating voice, and hands back the
/// isolated signal. Nothing is written to disk and nothing is cached: the caller owns the returned
/// samples and is expected to discard them as soon as it has derived what it needs.
///
/// **The decision this anchors to.** Chris approved the vocal-stem side-channel on 2026-08-08 after
/// listening to rendered stems. It exists for exactly one downstream consumer:
/// `AudioExtractor.Configuration.contourSource == .isolatedVoice`, where the melodic contour is
/// traced from the separated voice instead of from the full mix. Measured on "6 Human" (2026-08-08):
/// the mix yields 1190 note events at 4.27/s with 11% stepwise motion — noise; the isolated voice
/// yields 394 events at 1.41/s with 54% stepwise motion — a singable line.
///
/// **Constraints the code cannot show.**
/// - *The stem is transient.* No caller may cache, store, sync, or write the returned samples to a
///   user library. Zero storage growth is a product requirement, not an implementation detail. A
///   future "hear only your voice" feature would need caching and is explicitly NOT in this scope.
/// - *Only the contour may read it.* Chords, key, tempo, `voicingDensity`, take-type classification,
///   lyric transcription and the waveform envelope continue to read the FULL MIX. Measured reasons:
///   the stem reads `voicingDensity` 1.09 on a take whose mix reads 2.50 (a full-band take would
///   misclassify as a hum and cascade through every gate), and lyric transcription measured WORSE on
///   stems (23.9% word error vs 16.7-22.8% on the mix) because separation damages consonants.
/// - *Never run this on an instrument-only take.* Measured, isolation leaves sparse transient residue
///   peaking at -5 dBFS that a pitch tracker reads as plausible phantom notes that were never sung.
///   Deciding whether a take contains singing is the CALLER's job, from MIX-derived signals — see
///   `AudioExtractor.Configuration.ContourSource.isolatedVoice`.
/// - *The output can exceed full scale.* Measured peak 1.12 on "6 Human". Nothing here normalizes or
///   clips: any level-sensitive step downstream must handle a sample magnitude above 1.0.
/// - *Never call this on the main thread.* `instantiate` is bridged from an asynchronous callback via
///   a semaphore, and the render loop is CPU-bound (measured 82-97x realtime mono, 43-45x stereo on
///   an iPhone 17 Pro Max, thermals nominal, peak footprint under 129MB).
///
/// **Availability.** The AU is `macos(13.0)`/`ios(16.0)`, below MCC's `macOS 14`/`iOS 17` floors, so
/// it always links; presence is still checked at runtime via `AudioComponentFindNext` because a
/// Simulator or a future OS may not vend it. `kAUSoundIsolationSoundType_HighQualityVoice` is
/// `macos(15.0)`/`ios(18.0)` and is therefore requested behind an `#available` check with a runtime
/// fallback to the standard `_Voice` model.
///
/// Reference implementation validated on device 2026-08-08:
/// `WhisperBench/WhisperBench/StemProbe.swift` (component reported as "Apple: AUSoundIsolation"
/// version 1.6.0 on iOS 26.6). This type reuses its approach; every failure path throws
/// `VocalIsolator.Failure` and nothing traps.
public enum VocalIsolator {

    // MARK: - Errors

    /// Every way isolation can fail. Typed so a caller can fail soft on ALL of them identically —
    /// which is what `AudioExtractor` does: any throw means "keep the mix-derived contour", with no
    /// user-visible error.
    public enum Failure: Error, LocalizedError, Equatable {
        /// `AudioComponentFindNext` did not vend `aufx`/`vois`/`appl` on this system.
        case componentUnavailable
        /// The component exists but `AVAudioUnit.instantiate` handed back an error.
        case instantiationFailed(String)
        /// The source buffer carries no frames.
        case emptyInput
        /// Sample rate was zero, negative, or not finite.
        case invalidSampleRate(Double)
        /// Only non-interleaved Float32 buffers can be rendered (the AU's render format and the
        /// engine's manual-rendering format are both float32).
        case unsupportedFormat(String)
        /// The isolator renders mono or stereo only.
        case unsupportedChannelCount(Int)
        /// `kAudioUnitProperty_SupportedNumChannels` says the AU refuses this layout. Checked BEFORE
        /// connecting, because `AVAudioEngine.connect` raises an uncatchable ObjC exception on a
        /// layout the AU refuses and a trap is not a failure path.
        case channelCountRefused(Int, String)
        /// Engine setup, `renderOffline`, or buffer allocation failed.
        case renderFailed(String)
        /// The enclosing `Task` was cancelled mid-render. Surfaced rather than swallowed so the
        /// pipeline's cancellation posture (and BGProcessingTask expiry) stays intact.
        case cancelled

        public var errorDescription: String? {
            switch self {
            case .componentUnavailable:
                return "AUSoundIsolation is not available on this system."
            case let .instantiationFailed(detail):
                return "AUSoundIsolation would not instantiate: \(detail)"
            case .emptyInput:
                return "The source buffer has no audio frames."
            case let .invalidSampleRate(rate):
                return "Sample rate \(rate) is not a usable rate."
            case let .unsupportedFormat(detail):
                return "Unsupported audio format: \(detail)"
            case let .unsupportedChannelCount(count):
                return "Vocal isolation renders mono or stereo only; this buffer has \(count) channels."
            case let .channelCountRefused(count, supported):
                return "The AU does not accept \(count) channel audio. It reports supporting \(supported)."
            case let .renderFailed(detail):
                return "Offline render failed: \(detail)"
            case .cancelled:
                return "Vocal isolation was cancelled."
            }
        }
    }

    // MARK: - Tunables

    /// Frames pulled per `renderOffline` call. 4096 is the value the on-device measurement harness
    /// used (82-97x realtime mono, 43-45x stereo, peak footprint under 129MB) — large enough that
    /// per-pull overhead is noise, small enough that the memory plateau stays flat. Changing it
    /// invalidates those numbers.
    static let renderBlockFrames: AVAudioFrameCount = 4096

    // MARK: - Availability

    /// Whether `aufx`/`vois`/`appl` is present on this system, asked of the component manager rather
    /// than assumed from the OS version. Cheap and side-effect free. A `false` here is the one
    /// failure a caller can detect without paying for a render, which is why it is public: an app can
    /// skip scheduling isolation work entirely on a system that cannot do it.
    public static var isAvailable: Bool {
        var description = componentDescription()
        return AudioComponentFindNext(nil, &description) != nil
    }

    /// The description the whole feature hangs on: Apple's voice isolation effect. Verified on device
    /// 2026-08-08 — reported as "Apple: AUSoundIsolation" version 1.6.0 on iOS 26.6.
    static func componentDescription() -> AudioComponentDescription {
        AudioComponentDescription(
            componentType: kAudioUnitType_Effect,                   // 'aufx'
            componentSubType: kAudioUnitSubType_AUSoundIsolation,   // 'vois'
            componentManufacturer: kAudioUnitManufacturer_Apple,    // 'appl'
            componentFlags: 0,
            componentFlagsMask: 0
        )
    }

    // MARK: - Public isolation API

    /// Isolate the voice in a MONO Float32 buffer, returning the isolated samples at the same rate
    /// and (barring a short final render block) the same length, time-aligned with the input.
    ///
    /// This is the shape `AudioExtractor` consumes: its `buffer` parameter is already mono Float32.
    /// The returned samples can exceed ±1.0 (measured peak 1.12) — nothing normalizes them.
    ///
    /// - Important: Never call this on the main thread. See the type-level note.
    /// - Throws: `Failure` on every error path; nothing traps.
    public static func isolateVoice(_ buffer: [Float], sampleRate: Double) throws -> [Float] {
        guard !buffer.isEmpty else { throw Failure.emptyInput }
        guard sampleRate.isFinite, sampleRate > 0 else { throw Failure.invalidSampleRate(sampleRate) }

        guard
            let format = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: sampleRate,
                channels: 1,
                interleaved: false
            ),
            let source = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(buffer.count))
        else {
            throw Failure.renderFailed("could not build a \(sampleRate) Hz mono source buffer")
        }
        source.frameLength = AVAudioFrameCount(buffer.count)
        guard let destination = source.floatChannelData?[0] else {
            throw Failure.renderFailed("mono source buffer has no float channel data")
        }
        buffer.withUnsafeBufferPointer { pointer in
            if let base = pointer.baseAddress {
                destination.update(from: base, count: buffer.count)
            }
        }

        let isolated = try isolateVoice(source)
        guard let channel = isolated.floatChannelData?[0] else {
            throw Failure.renderFailed("isolated buffer has no float channel data")
        }
        return [Float](UnsafeBufferPointer(start: channel, count: Int(isolated.frameLength)))
    }

    /// Isolate the voice in a mono or stereo non-interleaved Float32 buffer.
    ///
    /// The returned buffer carries the same format as `source` and is head-trimmed by the AU's own
    /// reported latency (`kAudioUnitProperty_Latency`; measured 6360 frames at 48 kHz stereo, 4440
    /// mono) so its timings stay aligned with the recording. It is therefore the same length as
    /// `source`, except when the engine runs dry early — the final render block can be short, and the
    /// buffer's `frameLength` is authoritative.
    ///
    /// - Important: Never call this on the main thread. See the type-level note.
    /// - Throws: `Failure` on every error path; nothing traps.
    public static func isolateVoice(_ source: AVAudioPCMBuffer) throws -> AVAudioPCMBuffer {
        let format = source.format
        let sourceFrames = Int(source.frameLength)
        guard sourceFrames > 0 else { throw Failure.emptyInput }
        guard format.commonFormat == .pcmFormatFloat32, !format.isInterleaved else {
            throw Failure.unsupportedFormat("expected non-interleaved Float32, got \(format)")
        }
        let channelCount = Int(format.channelCount)
        guard channelCount == 1 || channelCount == 2 else {
            throw Failure.unsupportedChannelCount(channelCount)
        }
        var discovery = componentDescription()
        guard AudioComponentFindNext(nil, &discovery) != nil else { throw Failure.componentUnavailable }

        // -- graph: player -> AUSoundIsolation -> mainMixer, all in the caller's format.
        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        let effect = try instantiateEffect()
        let unit = effect.audioUnit

        // Ask the AU what layouts it accepts BEFORE connecting anything: AVAudioEngine.connect raises
        // an uncatchable ObjC exception on a layout the AU refuses, and this API's contract is that
        // every failure throws. (Measured on device the AU publishes "any in / any out", so this is a
        // guard against a future model, not against today's.)
        let channelSupport = supportedChannels(unit)
        guard channelSupport.accepts(channelCount) else {
            throw Failure.channelCountRefused(channelCount, channelSupport.descriptions.joined(separator: ", "))
        }

        engine.attach(player)
        engine.attach(effect)
        engine.connect(player, to: effect, format: format)
        engine.connect(effect, to: engine.mainMixerNode, format: format)

        // -- AU configuration, BEFORE the engine initializes the unit. `SoundToIsolate` picks which
        // model the AU loads and an AU is entitled to read that once at initialization, so
        // configuring only afterwards could quietly run the wrong model.
        _ = AudioUnitSetParameter(unit, kAUSoundIsolationParam_WetDryMixPercent, kAudioUnitScope_Global, 0, 100, 0)
        let choice = chooseSoundType(unit)

        do {
            try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: renderBlockFrames)
            try engine.start()
        } catch {
            throw Failure.renderFailed(error.localizedDescription)
        }
        defer {
            player.stop()
            engine.stop()
            engine.disableManualRenderingMode()
        }

        // Re-apply now that the unit is initialized, so the initialized unit and the running unit
        // agree, then VERIFY BY READING BACK. The read-back is not paranoia: the SoundToIsolate
        // parameter's historical declared range was 1...1, so a write of 0 (HighQualityVoice) can be
        // silently CLAMPED rather than rejected. A read-back of 0 with min 0 is what proves the newer
        // model is active.
        _ = AudioUnitSetParameter(unit, kAUSoundIsolationParam_WetDryMixPercent, kAudioUnitScope_Global, 0, 100, 0)
        _ = AudioUnitSetParameter(unit, kAUSoundIsolationParam_SoundToIsolate, kAudioUnitScope_Global, 0, choice, 0)

        // -- latency, read from the AU, never hardcoded.
        var latencySeconds: Float64 = 0
        var latencySize = UInt32(MemoryLayout<Float64>.size)
        let latencyStatus = AudioUnitGetProperty(
            unit, kAudioUnitProperty_Latency, kAudioUnitScope_Global, 0, &latencySeconds, &latencySize
        )
        if latencyStatus != noErr { latencySeconds = 0 }
        let trimFrames = headTrimFrames(latencySeconds: Double(latencySeconds), sampleRate: format.sampleRate)

        // -- render
        guard
            let block = AVAudioPCMBuffer(
                pcmFormat: engine.manualRenderingFormat,
                frameCapacity: engine.manualRenderingMaximumFrameCount
            ),
            let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(sourceFrames))
        else {
            throw Failure.renderFailed("could not allocate the render buffers")
        }
        output.frameLength = 0

        player.scheduleBuffer(source, at: nil, options: [], completionHandler: nil)
        player.play()

        // Pull the take PLUS the latency head, then drop that head, so the isolated signal comes out
        // the same length as the source and time-aligned with it.
        let totalFrames = totalFramesToRender(sourceFrames: sourceFrames, headTrimFrames: trimFrames)
        var rendered = 0
        var remainingTrim = trimFrames

        while rendered < totalFrames {
            // Cancellation is checked per block rather than only at the end: a 5-minute take is ~3500
            // blocks, so an expiring BGProcessingTask stops promptly instead of finishing the render.
            if Task.isCancelled { throw Failure.cancelled }

            let want = AVAudioFrameCount(min(Int(block.frameCapacity), totalFrames - rendered))
            let status: AVAudioEngineManualRenderingStatus
            do {
                status = try engine.renderOffline(want, to: block)
            } catch {
                throw Failure.renderFailed(error.localizedDescription)
            }
            guard status == .success else {
                throw Failure.renderFailed("renderOffline returned status \(status.rawValue)")
            }
            let produced = Int(block.frameLength)
            guard produced > 0 else { break }
            rendered += produced

            let split = headTrimSplit(producedFrames: produced, remainingTrim: remainingTrim)
            remainingTrim -= split.skip
            guard split.keep > 0 else { continue }

            let room = Int(output.frameCapacity) - Int(output.frameLength)
            let copyCount = min(split.keep, room)
            guard copyCount > 0 else { break }
            append(block, from: split.skip, count: copyCount, to: output)
        }

        guard output.frameLength > 0 else {
            throw Failure.renderFailed("the render produced no frames")
        }
        return output
    }

    // MARK: - Latency-trim arithmetic (pure)

    /// Frames of the AU's own reported latency to drop off the head of the render.
    ///
    /// The AU reports seconds via `kAudioUnitProperty_Latency`; the trim must be in frames at the
    /// render rate. Measured on device 2026-08-08: 0.1325 s → 6360 frames at 48 kHz stereo, and 4440
    /// frames for the mono configuration. Non-finite, zero, or negative inputs trim nothing (a broken
    /// latency report must not corrupt the alignment or eat the take).
    static func headTrimFrames(latencySeconds: Double, sampleRate: Double) -> Int {
        guard latencySeconds.isFinite, latencySeconds > 0,
              sampleRate.isFinite, sampleRate > 0 else { return 0 }
        let frames = (latencySeconds * sampleRate).rounded()
        guard frames.isFinite, frames > 0 else { return 0 }
        return Int(frames)
    }

    /// How many frames to pull in total so that, after the head trim, the output is the same length
    /// as the source. Pure so the arithmetic is unit-testable without an AudioUnit.
    static func totalFramesToRender(sourceFrames: Int, headTrimFrames: Int) -> Int {
        max(0, sourceFrames) + max(0, headTrimFrames)
    }

    /// Split one produced render block into the leading frames still owed to the head trim and the
    /// frames that reach the output. The trim usually straddles a block boundary, which is the only
    /// reason this is not a single subtraction.
    static func headTrimSplit(producedFrames: Int, remainingTrim: Int) -> (skip: Int, keep: Int) {
        guard producedFrames > 0 else { return (0, 0) }
        let skip = max(0, min(remainingTrim, producedFrames))
        return (skip, producedFrames - skip)
    }

    // MARK: - AU helpers

    /// `AVAudioUnit.instantiate` rather than the `AVAudioUnitEffect` initializer: it hands back an
    /// Error instead of raising an uncatchable ObjC exception, which is the difference between a
    /// typed failure and a crash. The callback is bridged to a synchronous return through a
    /// semaphore — hence the standing "never on the main thread" rule for this whole type.
    private static func instantiateEffect() throws -> AVAudioUnit {
        let semaphore = DispatchSemaphore(value: 0)
        let box = InstantiationBox()
        AVAudioUnit.instantiate(with: componentDescription(), options: []) { unit, error in
            box.set(unit: unit, error: error)
            semaphore.signal()
        }
        semaphore.wait()
        if let unit = box.unit { return unit }
        throw Failure.instantiationFailed(
            box.error?.localizedDescription ?? "AVAudioUnit.instantiate returned no unit and no error."
        )
    }

    /// Carries the instantiate callback's result across the semaphore.
    private final class InstantiationBox: @unchecked Sendable {
        private let lock = NSLock()
        private var storedUnit: AVAudioUnit?
        private var storedError: Error?

        func set(unit: AVAudioUnit?, error: Error?) {
            lock.lock()
            storedUnit = unit
            storedError = error
            lock.unlock()
        }

        var unit: AVAudioUnit? { lock.lock(); defer { lock.unlock() }; return storedUnit }
        var error: Error? { lock.lock(); defer { lock.unlock() }; return storedError }
    }

    /// What `kAudioUnitProperty_SupportedNumChannels` says the AU will take.
    struct ChannelSupport {
        /// Human-readable pairs such as "1 in / 1 out". When the AU does not implement the property
        /// this is the "any layout" sentinel — by AU convention, not implementing it means anything
        /// goes, so `accepts` must return true rather than refusing everything.
        let descriptions: [String]
        private let pairs: [(input: Int, output: Int)]

        init(pairs: [(input: Int, output: Int)]) {
            self.pairs = pairs
            descriptions = pairs.isEmpty
                ? ["any layout (the AU does not publish the property)"]
                : pairs.map { pair in
                    let input = pair.input < 0 ? "any" : "\(pair.input)"
                    let output = pair.output < 0 ? "any" : "\(pair.output)"
                    return "\(input) in / \(output) out"
                }
        }

        /// A negative entry is the AU's wildcard for "any channel count".
        func accepts(_ count: Int) -> Bool {
            guard !pairs.isEmpty else { return true }
            return pairs.contains { pair in
                (pair.input < 0 || pair.input == count) && (pair.output < 0 || pair.output == count)
            }
        }
    }

    private static func supportedChannels(_ unit: AudioUnit) -> ChannelSupport {
        var size: UInt32 = 0
        var writable: DarwinBoolean = false
        let infoStatus = AudioUnitGetPropertyInfo(
            unit, kAudioUnitProperty_SupportedNumChannels, kAudioUnitScope_Global, 0, &size, &writable
        )
        let stride = UInt32(MemoryLayout<AUChannelInfo>.size)
        guard infoStatus == noErr, size >= stride else { return ChannelSupport(pairs: []) }

        let count = Int(size / stride)
        var entries = [AUChannelInfo](repeating: AUChannelInfo(inChannels: 0, outChannels: 0), count: count)
        var readSize = size
        let status = entries.withUnsafeMutableBufferPointer { pointer -> OSStatus in
            guard let base = pointer.baseAddress else { return kAudio_ParamError }
            return AudioUnitGetProperty(
                unit, kAudioUnitProperty_SupportedNumChannels, kAudioUnitScope_Global, 0, base, &readSize
            )
        }
        guard status == noErr else { return ChannelSupport(pairs: []) }
        return ChannelSupport(pairs: entries.map { (Int($0.inChannels), Int($0.outChannels)) })
    }

    /// Ask for `HighQualityVoice` (the iOS 18 / macOS 15 model, value 0) and VERIFY IT STUCK by
    /// reading the parameter back; otherwise use the standard `_Voice` model (value 1).
    ///
    /// The read-back is required, not defensive: the parameter's historical declared range was 1...1,
    /// so on an older model a write of 0 is either rejected outright or SILENTLY CLAMPED back to 1.
    /// Both outcomes look like success from the `OSStatus` alone. Measured on device 2026-08-08 the
    /// newer model is active (read-back 0, min 0, max 1, no fallback used).
    ///
    /// Returns the value the unit is left holding, so the render and the configuration cannot
    /// disagree.
    private static func chooseSoundType(_ unit: AudioUnit) -> AudioUnitParameterValue {
        // The constant itself is macos(15.0)/ios(18.0) while MCC's floors are macOS 14 / iOS 17, so
        // it can only be named inside the availability check. On an older OS the standard model is
        // the only one that exists and is the correct answer, not a degraded one.
        guard #available(iOS 18.0, macOS 15.0, *) else {
            let standard = AudioUnitParameterValue(kAUSoundIsolationSoundType_Voice)
            _ = AudioUnitSetParameter(unit, kAUSoundIsolationParam_SoundToIsolate, kAudioUnitScope_Global, 0, standard, 0)
            return standard
        }

        let highQuality = AudioUnitParameterValue(kAUSoundIsolationSoundType_HighQualityVoice)
        let standard = AudioUnitParameterValue(kAUSoundIsolationSoundType_Voice)
        let status = AudioUnitSetParameter(
            unit, kAUSoundIsolationParam_SoundToIsolate, kAudioUnitScope_Global, 0, highQuality, 0
        )
        // A nil read-back means the GETTER failed; that is not evidence the set was rejected, so it
        // is treated as "stuck" rather than triggering a needless downgrade.
        let readBack = parameterValue(unit, kAUSoundIsolationParam_SoundToIsolate)
        let stuck = readBack.map { abs($0 - Double(highQuality)) < 0.001 } ?? true
        if status == noErr, stuck { return highQuality }

        _ = AudioUnitSetParameter(unit, kAUSoundIsolationParam_SoundToIsolate, kAudioUnitScope_Global, 0, standard, 0)
        return standard
    }

    private static func parameterValue(_ unit: AudioUnit, _ parameter: AudioUnitParameterID) -> Double? {
        var value: AudioUnitParameterValue = 0
        let status = AudioUnitGetParameter(unit, parameter, kAudioUnitScope_Global, 0, &value)
        return status == noErr ? Double(value) : nil
    }

    // MARK: - Buffer helpers

    /// Append `count` frames of `block`, starting at `offset`, to `output`. Channel-wise `memcpy`
    /// because both buffers are non-interleaved Float32 with the same channel count.
    private static func append(
        _ block: AVAudioPCMBuffer,
        from offset: Int,
        count: Int,
        to output: AVAudioPCMBuffer
    ) {
        guard count > 0,
              let source = block.floatChannelData,
              let destination = output.floatChannelData else { return }
        let channels = min(Int(block.format.channelCount), Int(output.format.channelCount))
        let start = Int(output.frameLength)
        for channel in 0..<channels {
            memcpy(
                destination[channel].advanced(by: start),
                source[channel].advanced(by: offset),
                count * MemoryLayout<Float>.size
            )
        }
        output.frameLength = AVAudioFrameCount(start + count)
    }
}
