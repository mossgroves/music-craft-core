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

        // Overlapping windows + seam trimming, matching upstream basic_pitch unwrap
        // (spotify/basic-pitch @ fa5997af — get_audio_input / window_audio_file / unwrap_output).
        // Front-pad by overlapLen/2 zeros so the first window's trimmed leading frames are padding
        // (keeps t=0 aligned: the front-pad is exactly framesTrimmedPerEdge frames, which the
        // edge-trim then removes); stride hopSize (overlapping); zero-pad the tail window to
        // nSamples; trim framesTrimmedPerEdge frames from BOTH ends of EACH window's output before
        // concatenating; finally trim the concatenation to the frame count for the original
        // (unpadded) length. Because the front-pad and the first window's leading trim cancel, the
        // existing `frame * secondsPerFrame + alignmentOffset` time mapping is preserved.
        let frontPad = Constants.overlapLen / 2          // int(overlap_len / 2) = 3840 samples
        var padded = [Float](repeating: 0, count: frontPad)
        padded.append(contentsOf: resampled)

        var frames: [[Double]] = []   // F × 88   (note activations)
        var onsets: [[Double]] = []   // F × 88
        var contourRows: [[Double]] = [] // F × 264

        var start = 0
        while start < padded.count {
            var window = Array(padded[start ..< min(start + Constants.nSamples, padded.count)])
            if window.count < Constants.nSamples {
                window.append(contentsOf: repeatElement(0, count: Constants.nSamples - window.count))
            }
            let (n, o, c) = try infer(window: window)
            Self.appendTrimmingEdges(n, into: &frames)
            Self.appendTrimmingEdges(o, into: &onsets)
            Self.appendTrimmingEdges(c, into: &contourRows)
            start += Constants.hopSize
        }

        // Tail-trim to the number of frames upstream keeps for the original length:
        //   int((audio_original_length / hop_size) * n_frames_per_window)   (unwrap_output)
        // where audio_original_length is the resampled (pre-front-pad) sample count.
        let keepFrames = min(
            frames.count,
            max(0, Int((Double(resampled.count) / Double(Constants.hopSize)) * Double(Constants.framesKeptPerWindow)))
        )
        frames = Array(frames.prefix(keepFrames))
        onsets = Array(onsets.prefix(keepFrames))
        contourRows = Array(contourRows.prefix(keepFrames))

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

    // MARK: - Unwrap

    /// Append one window's output matrix, dropping `framesTrimmedPerEdge` frames from the start and
    /// the end — upstream `unwrap_output`'s `output[:, n_olap:-n_olap, :]`, applied per window.
    /// Defensive: if a window has too few frames to trim, it contributes nothing (a full window
    /// emits `annotNFrames` (172) frames, so this guard is not expected to trigger in practice).
    private static func appendTrimmingEdges(_ m: [[Double]], into acc: inout [[Double]]) {
        let n = Constants.framesTrimmedPerEdge
        guard m.count > 2 * n else { return }
        acc.append(contentsOf: m[n ..< (m.count - n)])
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

        // Overlapping-window unwrap (spotify/basic-pitch @ fa5997af — inference.py: run_inference,
        // get_audio_input, window_audio_file, unwrap_output). Windows overlap by nOverlappingFrames;
        // on unwrap, half that many frames are trimmed from each window edge (the model's
        // predictions degrade at a window's temporal boundaries — this removes the seam artifacts).
        static let nOverlappingFrames: Int = 30                       // DEFAULT_OVERLAPPING_FRAMES (inference.py)
        static let overlapLen: Int = nOverlappingFrames * fftHop      // OVERLAP_LEN = 30*256 = 7680 samples
        static let hopSize: Int = nSamples - overlapLen               // HOP_SIZE = 43844-7680 = 36164 samples
        static let annotationsFps: Int = Int(sampleRate) / fftHop     // ANNOTATIONS_FPS = 22050//256 = 86 (floor)
        static let annotNFrames: Int = annotationsFps * windowSeconds // ANNOT_N_FRAMES = 86*2 = 172
        static let framesTrimmedPerEdge: Int = nOverlappingFrames / 2 // int(0.5*30) = 15
        static let framesKeptPerWindow: Int = annotNFrames - nOverlappingFrames // 172-30 = 142
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
