import Foundation
import CoreML
import Accelerate

/// Audio → polyphonic note events + frame-level pitch contour, using Spotify's bundled
/// **Basic Pitch** Core ML model (Apache-2.0; see `NOTICE` and
/// `docs/security/basic-pitch-2026-05-31.md`).
///
/// Phase 1 of the 0.0.14 adoption (`specs/0.0.14-basic-pitch-adoption.md`): purely additive.
/// This type does **not** touch `AudioExtractor`, `PitchDetector`, `OnsetDetector`, or any
/// `Result` type — it is a standalone transcriber, safe to delete.
///
/// ## Verified model I/O (against `spotify/basic-pitch` @ fa5997af, release v0.4.0)
/// - Input  `input_2`  : mono window, `(1, 43844, 1)` float, 22050 Hz.
/// - Output `Identity`   → contour activations `(1, F, 264)`  (88 keys × 3 bins/semitone).
/// - Output `Identity_1` → note    activations `(1, F, 88)`.
/// - Output `Identity_2` → onset   activations `(1, F, 88)`.
/// The three outputs carry generic TF→CoreML names; the head mapping is taken from upstream
/// `basic_pitch/inference.py`. Velocity and pitch-bend are **not** model outputs — they are
/// derived in upstream Python post-processing; velocity (amplitude) is ported here, pitch-bend
/// is deferred in Phase 1 (`pitchBend == nil`).
public struct BasicPitchTranscriber {

    // MARK: Public API

    public struct Configuration: Equatable, Hashable, Sendable {
        /// Minimum onset-activation amplitude for an onset to count. Upstream default 0.5.
        public let onsetThreshold: Double
        /// Minimum per-frame activation for a note to stay "on". Upstream default 0.3.
        public let frameThreshold: Double
        /// Drop notes shorter than this. Upstream default 127.70 ms.
        public let minNoteDurationMs: Double

        public init(onsetThreshold: Double = 0.5,
                    frameThreshold: Double = 0.3,
                    minNoteDurationMs: Double = 127.70) {
            self.onsetThreshold = onsetThreshold
            self.frameThreshold = frameThreshold
            self.minNoteDurationMs = minNoteDurationMs
        }

        public static let `default` = Configuration()
    }

    public struct Transcription: Equatable, Sendable {
        public let notes: [TranscribedNote]
        public let contour: [PitchFrame]
        public let duration: TimeInterval
    }

    public enum TranscriptionError: Error, Equatable {
        case modelResourceMissing
        case modelLoadFailed(String)
        case inferenceFailed(String)
        case invalidInput(String)
    }

    private let model: MLModel
    private let configuration: Configuration

    /// Loads the bundled Basic Pitch Core ML model. Throws (never crashes) if the resource is
    /// missing or Core ML cannot compile/load it. The `.mlpackage` is compiled to `.mlmodelc`
    /// at runtime via `MLModel.compileModel(at:)` — SwiftPM's CLI build does not run `coremlc`,
    /// so we do not rely on a precompiled resource.
    public init(configuration: Configuration = .default) throws {
        self.configuration = configuration
        guard let url = Bundle.module.url(forResource: "nmp", withExtension: "mlpackage") else {
            throw TranscriptionError.modelResourceMissing
        }
        do {
            let compiled = try Self.compile(url)
            self.model = try MLModel(contentsOf: compiled)
        } catch let e as TranscriptionError {
            throw e
        } catch {
            throw TranscriptionError.modelLoadFailed(String(describing: error))
        }
    }

    /// Transcribe a mono PCM buffer. The buffer is resampled to the model's 22050 Hz rate
    /// internally, so callers may pass audio at any sample rate.
    public func transcribe(_ samples: [Float], sampleRate: Double) throws -> Transcription {
        guard sampleRate > 0 else { throw TranscriptionError.invalidInput("sampleRate must be > 0") }

        // Empty input → empty transcription (no inference).
        if samples.isEmpty {
            return Transcription(notes: [], contour: [], duration: 0)
        }

        let duration = Double(samples.count) / sampleRate

        // Sanitize non-finite samples, then resample to the model rate.
        let clean = samples.map { $0.isFinite ? $0 : 0 }
        let resampled = Self.resample(clean, from: sampleRate, to: Constants.sampleRate)

        // Window into fixed AUDIO_N_SAMPLES chunks (zero-padded tail). PHASE-1 SIMPLIFICATION:
        // non-overlapping windows. Upstream overlaps windows by 30 frames to suppress
        // boundary artifacts and trims them on unwrap; we omit the overlap here (documented
        // deviation — revisit if device validation shows boundary artifacts).
        var frames: [[Double]] = []   // F × 88   (note activations)
        var onsets: [[Double]] = []   // F × 88
        var contourRows: [[Double]] = [] // F × 264

        var start = 0
        while start < resampled.count {
            var window = Array(resampled[start ..< min(start + Constants.nSamples, resampled.count)])
            if window.count < Constants.nSamples {
                window.append(contentsOf: repeatElement(0, count: Constants.nSamples - window.count))
            }
            let (n, o, c) = try infer(window: window)
            frames.append(contentsOf: n)
            onsets.append(contentsOf: o)
            contourRows.append(contentsOf: c)
            start += Constants.nSamples
        }

        let minNoteLenFrames = Int((configuration.minNoteDurationMs / 1000.0 * Constants.framesPerSecond).rounded())
        let events = BasicPitchDecoder.outputToNotes(
            frames: frames,
            onsets: onsets,
            onsetThresh: configuration.onsetThreshold,
            frameThresh: configuration.frameThreshold,
            minNoteLen: minNoteLenFrames
        )

        let notes = events.map { ev -> TranscribedNote in
            TranscribedNote(
                pitchMIDI: ev.freqIdx + Constants.midiOffset,
                onsetTime: Double(ev.startFrame) * Constants.secondsPerFrame + Constants.alignmentOffset,
                duration: Double(ev.endFrame - ev.startFrame) * Constants.secondsPerFrame,
                velocity: min(1, max(0, ev.amplitude)),
                pitchBend: nil  // Phase 1: deferred (see security doc / NOTICE).
            )
        }.sorted { $0.onsetTime < $1.onsetTime }

        let contour = contourRows.enumerated().compactMap { (f, row) -> PitchFrame? in
            guard let (bin, conf) = row.enumerated().max(by: { $0.element < $1.element }) else { return nil }
            return PitchFrame(
                time: Double(f) * Constants.secondsPerFrame + Constants.alignmentOffset,
                frequencyHz: Constants.contourBinFrequency(bin),
                confidence: min(1, max(0, conf))
            )
        }

        return Transcription(notes: notes, contour: contour, duration: duration)
    }

    // MARK: - Inference

    /// Run one model window. Returns (note F×88, onset F×88, contour F×264).
    private func infer(window: [Float]) throws -> ([[Double]], [[Double]], [[Double]]) {
        let input: MLMultiArray
        do {
            input = try MLMultiArray(shape: [1, NSNumber(value: Constants.nSamples), 1], dataType: .float32)
        } catch {
            throw TranscriptionError.inferenceFailed("input alloc: \(error)")
        }
        let ptr = input.dataPointer.bindMemory(to: Float.self, capacity: Constants.nSamples)
        for i in 0 ..< Constants.nSamples { ptr[i] = window[i] }

        let out: MLFeatureProvider
        do {
            let provider = try MLDictionaryFeatureProvider(dictionary: ["input_2": MLFeatureValue(multiArray: input)])
            out = try model.prediction(from: provider)
        } catch {
            throw TranscriptionError.inferenceFailed(String(describing: error))
        }

        guard let contour = out.featureValue(for: "Identity")?.multiArrayValue,
              let note = out.featureValue(for: "Identity_1")?.multiArrayValue,
              let onset = out.featureValue(for: "Identity_2")?.multiArrayValue else {
            throw TranscriptionError.inferenceFailed("missing expected outputs Identity/Identity_1/Identity_2")
        }
        return (try Self.matrix(note), try Self.matrix(onset), try Self.matrix(contour))
    }

    /// Convert a Core ML `(1, F, B)` multi-array to an `F × B` matrix of Doubles, using strides.
    private static func matrix(_ a: MLMultiArray) throws -> [[Double]] {
        let shape = a.shape.map { $0.intValue }
        guard shape.count == 3, shape[0] == 1 else {
            throw TranscriptionError.inferenceFailed("unexpected output rank/shape \(shape)")
        }
        let F = shape[1], B = shape[2]
        let strides = a.strides.map { $0.intValue }
        let s1 = strides[1], s2 = strides[2]
        var result = [[Double]](repeating: [Double](repeating: 0, count: B), count: F)
        switch a.dataType {
        case .float32:
            let p = a.dataPointer.bindMemory(to: Float.self, capacity: a.count)
            for f in 0..<F { for b in 0..<B { result[f][b] = Double(p[f * s1 + b * s2]) } }
        case .double:
            let p = a.dataPointer.bindMemory(to: Double.self, capacity: a.count)
            for f in 0..<F { for b in 0..<B { result[f][b] = p[f * s1 + b * s2] } }
        default:
            for f in 0..<F { for b in 0..<B { result[f][b] = a[[0, f, b] as [NSNumber]].doubleValue } }
        }
        return result
    }

    // MARK: - Resampling (vDSP linear interpolation)

    /// Linear-interpolation resample of a mono buffer, `inRate → outRate`. Bounded and pure;
    /// returns the input unchanged when the rates match. Empty input → empty output.
    static func resample(_ input: [Float], from inRate: Double, to outRate: Double) -> [Float] {
        if input.isEmpty || inRate == outRate { return input }
        let ratio = inRate / outRate
        let outCount = max(1, Int((Double(input.count) / ratio).rounded()))
        // Control vector of fractional source indices, clamped to a valid interpolation range.
        var control = [Float](repeating: 0, count: outCount)
        let maxIndex = Float(input.count - 1)
        for i in 0..<outCount {
            control[i] = min(Float(Double(i) * ratio), maxIndex)
        }
        var output = [Float](repeating: 0, count: outCount)
        // vDSP_vlint interpolates `input` at the fractional positions in `control`.
        // It reads index trunc(control[i]) and trunc(control[i])+1, so pad input by one sample.
        var padded = input
        padded.append(input[input.count - 1])
        vDSP_vlint(padded, control, 1, &output, 1, vDSP_Length(outCount), vDSP_Length(padded.count))
        return output
    }

    // MARK: - Core ML runtime compilation

    private static func compile(_ url: URL) throws -> URL {
        let sem = DispatchSemaphore(value: 0)
        var outcome: Result<URL, Error>?
        MLModel.compileModel(at: url) { result in
            outcome = result
            sem.signal()
        }
        sem.wait()
        switch outcome {
        case .success(let compiled): return compiled
        case .failure(let e): throw TranscriptionError.modelLoadFailed("compile: \(e)")
        case .none: throw TranscriptionError.modelLoadFailed("compile: no result")
        }
    }

    // MARK: - Model constants (from spotify/basic-pitch constants.py @ fa5997af)

    enum Constants {
        static let sampleRate: Double = 22050        // AUDIO_SAMPLE_RATE
        static let fftHop: Int = 256                 // FFT_HOP
        static let windowSeconds: Int = 2            // AUDIO_WINDOW_LENGTH
        static let nSamples: Int = 22050 * 2 - 256   // AUDIO_N_SAMPLES = 43844
        static let nSemitones: Int = 88              // ANNOTATIONS_N_SEMITONES
        static let contourBinsPerSemitone: Int = 3   // CONTOURS_BINS_PER_SEMITONE
        static let midiOffset: Int = 21              // MIDI_OFFSET (A0)
        static let baseFrequency: Double = 27.5      // ANNOTATIONS_BASE_FREQUENCY (A0)
        static let alignmentOffset: Double = 0.0018  // MAGIC_ALIGNMENT_OFFSET

        static var framesPerSecond: Double { sampleRate / Double(fftHop) }   // ANNOTATIONS_FPS ≈ 86.13
        static var secondsPerFrame: Double { Double(fftHop) / sampleRate }

        /// Centre frequency (Hz) of a contour bin (3 bins/semitone above A0=27.5 Hz).
        static func contourBinFrequency(_ bin: Int) -> Double {
            let d = pow(2.0, 1.0 / (12.0 * Double(contourBinsPerSemitone)))
            return baseFrequency * pow(d, Double(bin))
        }
    }
}

public struct TranscribedNote: Equatable, Hashable, Sendable {
    public let pitchMIDI: Int
    public let onsetTime: TimeInterval
    public let duration: TimeInterval
    public let velocity: Double          // 0…1 (mean note-activation amplitude)
    public let pitchBend: [Double]?      // Phase 1: always nil (derivation deferred)

    public init(pitchMIDI: Int, onsetTime: TimeInterval, duration: TimeInterval, velocity: Double, pitchBend: [Double]?) {
        self.pitchMIDI = pitchMIDI
        self.onsetTime = onsetTime
        self.duration = duration
        self.velocity = velocity
        self.pitchBend = pitchBend
    }
}

public struct PitchFrame: Equatable, Hashable, Sendable {
    public let time: TimeInterval
    public let frequencyHz: Double
    public let confidence: Double        // 0…1

    public init(time: TimeInterval, frequencyHz: Double, confidence: Double) {
        self.time = time
        self.frequencyHz = frequencyHz
        self.confidence = confidence
    }
}
