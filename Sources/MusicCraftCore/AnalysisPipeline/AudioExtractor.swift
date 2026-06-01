import Foundation

/// Offline audio analysis pipeline producing chord progressions, key, contour, and detected notes from a PCM buffer.
///
/// AudioExtractor transcribes the buffer with a bundled **Basic Pitch** Core ML model and derives every
/// `Result` field from the note transcription: note-native chord segments (`NoteChordIdentifier`), key
/// (`ProgressionAnalyzer` over the chords, with a `MelodyKeyInference` fallback), a melodic contour, and the
/// raw detected notes.
///
/// **Key inference strategy:**
/// 1. If chord segments produce a usable progression (≥2 distinct chords), use ProgressionAnalyzer.inferKey (chord-based).
/// 2. Else if detected notes are populated, use MelodyKeyInference.infer (pitch-class-based) and take the top candidate's key.
/// 3. Else Result.key is nil.
///
/// This two-path approach leverages the strongest signal available: chord progressions when the audio contains
/// harmonic content, pitch class distributions when it contains melody only.
///
/// **Note/chord source:** the bundled Basic Pitch model is the single transcription front-end (the hand-rolled
/// YIN + FFT-chroma DSP pipeline was removed in 0.1.0). `detectedNotes` is the full polyphonic transcription
/// (key/harmony read the harmonic content from it); `contour` is a melodic-skyline reduction of the same notes;
/// `chordSegments` are note-native names over 1 s windows.
///
/// **I/O:** the model is loaded the first time `extract` runs (once, process-wide via a cached `static let`), so
/// the type is no longer a pure / no-I/O function. If the model can't load, `extract` degrades to a well-formed
/// empty `Result` rather than crashing.
public enum AudioExtractor {

    /// Extract chord segments, key, melodic contour, and detected notes from an audio buffer.
    ///
    /// - Parameters:
    ///   - buffer: Mono Float32 PCM samples.
    ///   - sampleRate: Sample rate in Hz (typically 44100 or 48000).
    ///   - configuration: Optional tuning. Retained for API compatibility; the Basic Pitch front-end derives
    ///     its own note events, so the legacy DSP-tuning fields are vestigial under the current path.
    /// - Returns: Bundled extraction result.
    public static func extract(
        buffer: [Float],
        sampleRate: Double,
        configuration: Configuration = .default
    ) -> Result {
        let duration = TimeInterval(buffer.count) / sampleRate

        // Near-silence guard. The Basic Pitch model emits a handful of phantom notes (and therefore a
        // spurious key/chord) on essentially-silent input — an all-zero buffer decoded to ~16 notes + a
        // key. If the buffer carries no meaningful signal, return an empty Result before running the
        // model. The floor is a peak amplitude of `silenceFloorPeak` (~-60 dBFS): orders of magnitude
        // below a real quiet nylon take (device captures peak ~0.30–0.52 on the device-test recordings),
        // so it only catches digital / near silence and never suppresses real fingerpicking.
        let peak = buffer.lazy.map { Swift.abs($0) }.max() ?? 0
        guard peak >= silenceFloorPeak else {
            return Result(chordSegments: [], key: nil, contour: [], detectedNotes: [], duration: duration)
        }

        guard let transcriber = sharedBasicPitchTranscriber,
              let transcription = try? transcriber.transcribe(buffer, sampleRate: sampleRate) else {
            // Model unavailable (or buffer empty) → never crash; emit a well-formed empty Result.
            return Result(chordSegments: [], key: nil, contour: [], detectedNotes: [], duration: duration)
        }
        let notes = transcription.notes
        let chordSegments = noteNativeChordSegments(notes: notes, duration: duration)   // FULL polyphony → note-native (the validated win)
        // detectedNotes = FULL polyphony. Sanctuary's melody-key inference AND its harmony timeline
        // both consume Result.detectedNotes; the skyline melodic reduction misread the key on
        // instrument input (a D–A take read C♯ minor instead of D/A major), because a single melodic
        // line drops the harmonic content the key/harmony stages need. Full polyphony fixes both with
        // no Sanctuary change. The contour stays a single melodic line via a locally-computed skyline.
        let detectedNotes = notes.map {
            DetectedNote(midiNote: $0.pitchMIDI,
                         onsetTime: $0.onsetTime,
                         duration: max(0.001, $0.duration),
                         confidence: min(1, max(0.1, $0.velocity)))
        }
        let contour = deriveContour(from: skyline(of: notes))                           // contour = melodic skyline (single line)
        let key = inferKey(from: chordSegments, fallbackNotes: detectedNotes)           // chord-based first, full-poly fallback
        return Result(chordSegments: chordSegments, key: key, contour: contour, detectedNotes: detectedNotes, duration: duration)
    }

    // MARK: - Basic Pitch note source

    /// Peak-amplitude floor (~-60 dBFS) below which `extract` treats the buffer as silence and returns
    /// an empty Result without running the model. Far below any real capture (the device-test nylon
    /// recordings peak at ~0.30–0.52), so it only catches digital / near silence.
    private static let silenceFloorPeak: Float = 1e-3

    /// Process-wide cached Basic Pitch transcriber. A Swift `static let` is initialized exactly once
    /// (lazily, thread-safe), so the bundled Core ML model is compiled + loaded a single time and
    /// reused across every `extract` call — no per-call recompile. `nil` if the model can't load
    /// (the path then degrades to a well-formed empty Result).
    private static let sharedBasicPitchTranscriber: BasicPitchTranscriber? = try? BasicPitchTranscriber()

    /// Note-native chord segments from full polyphony: 1.0 s window / 0.5 s hop (single window if the
    /// clip is shorter than one window), each window weighted by `overlapSeconds × velocity` per pitch
    /// class with the lowest sounding note as bass, named by `NoteChordIdentifier`. Consecutive identical
    /// names collapse into contiguous, non-overlapping `ChordSegment`s.
    private static func noteNativeChordSegments(notes: [TranscribedNote], duration: TimeInterval) -> [ChordSegment] {
        guard !notes.isEmpty, duration > 0 else { return [] }
        let windowLen = 1.0, hop = 0.5

        var starts: [Double] = []
        if duration <= windowLen { starts = [0] }
        else { var s = 0.0; while s < duration { starts.append(s); s += hop } }

        // Per-window identified chord (nil where none), with its [start, end] and confidence.
        var win: [(start: Double, chord: Chord?, conf: Double)] = []
        for s in starts {
            let e = min(s + windowLen, duration)
            var bins = [Double](repeating: 0, count: 12)
            var lowest = Int.max
            for n in notes {
                let overlap = max(0, min(n.onsetTime + n.duration, e) - max(n.onsetTime, s))
                guard overlap > 0 else { continue }
                bins[((n.pitchMIDI % 12) + 12) % 12] += overlap * max(0, n.velocity)
                if n.pitchMIDI < lowest { lowest = n.pitchMIDI }
            }
            let bass = lowest == Int.max ? nil : ((lowest % 12) + 12) % 12
            let id = NoteChordIdentifier.identify(weightedPitchClasses: bins, bassPitchClass: bass)
            win.append((s, id?.chord, id?.confidence ?? 0))
        }

        // Collapse consecutive identical chord names into runs (start + mean confidence).
        var runs: [(start: Double, chord: Chord, conf: Double)] = []
        var i = 0
        while i < win.count {
            guard let chord = win[i].chord else { i += 1; continue }
            var j = i
            while j + 1 < win.count, let next = win[j + 1].chord, next.displayName == chord.displayName { j += 1 }
            let confs = win[i...j].map { $0.conf }
            runs.append((win[i].start, chord, confs.reduce(0, +) / Double(confs.count)))
            i = j + 1
        }

        // Assign contiguous, non-overlapping end times (next run's start, or duration for the last).
        return runs.enumerated().map { (k, r) in
            let end = k + 1 < runs.count ? runs[k + 1].start : duration
            // Reuse the existing `.classifier` DetectionMethod case — the enum is frozen for Sanctuary;
            // a dedicated `.noteNative` case is a later additive option.
            return ChordSegment(startTime: r.start, endTime: end, chord: r.chord, confidence: r.conf, detectionMethod: .classifier)
        }
    }

    /// First-pass melodic reduction: the highest-pitched sounding note at each instant, emitted as a
    /// monophonic `[DetectedNote]` (preserves the field's "monophonic melodic events" semantics).
    private static func skyline(of notes: [TranscribedNote]) -> [DetectedNote] {
        guard !notes.isEmpty else { return [] }
        var boundsSet = Set<Double>()
        for n in notes { boundsSet.insert(n.onsetTime); boundsSet.insert(n.onsetTime + n.duration) }
        let times = boundsSet.sorted()
        guard times.count >= 2 else { return [] }

        // Highest active note per slice (sampled at the slice midpoint).
        var sliceTop: [(midi: Int, vel: Double)?] = []
        for k in 0..<(times.count - 1) {
            let mid = (times[k] + times[k + 1]) / 2
            var top: TranscribedNote?
            for n in notes where n.onsetTime <= mid && mid < n.onsetTime + n.duration {
                if top == nil || n.pitchMIDI > top!.pitchMIDI { top = n }
            }
            sliceTop.append(top.map { ($0.pitchMIDI, $0.velocity) })
        }

        // Merge consecutive slices that share a top pitch into single monophonic notes.
        var out: [DetectedNote] = []
        var k = 0
        while k < sliceTop.count {
            guard let cur = sliceTop[k] else { k += 1; continue }
            var j = k
            while j + 1 < sliceTop.count, let nxt = sliceTop[j + 1], nxt.midi == cur.midi { j += 1 }
            out.append(DetectedNote(
                midiNote: cur.midi,
                onsetTime: times[k],
                duration: max(0.001, times[j + 1] - times[k]),
                confidence: min(1, max(0.1, cur.vel))
            ))
            k = j + 1
        }
        return out
    }

    // MARK: - Configuration

    /// Tuning parameters for audio extraction.
    ///
    /// These fields tuned the removed YIN + FFT-chroma DSP pipeline and are now vestigial under the
    /// Basic Pitch front-end. They are retained so existing call sites (`Configuration()` / `.default`)
    /// stay source-compatible; the Basic Pitch path does not read them.
    public struct Configuration: Equatable, Hashable, Sendable {
        /// Minimum gap between successive onsets in milliseconds. Default 500.
        public let onsetMinGapMs: Double
        /// Energy multiplier for onset detection threshold. Default 2.0.
        public let onsetEnergyMultiplier: Float
        /// Absolute minimum RMS energy for onset detection. Default 0.005.
        public let onsetEnergyFloor: Float
        /// Chroma analysis window size in samples. Default 8192.
        public let chromaWindowSize: Int
        /// Chroma analysis hop size in samples. Default 4096 (50% overlap).
        public let chromaHopSize: Int
        /// Early-frame attack skip in frames. Default 2 (skip first 2 frames per segment for attack settling).
        public let earlyFrameAttackSkip: Int
        /// Early-frame averaging window size in frames. Default 8.
        public let earlyFrameWindowSize: Int
        /// Minimum extraction confidence (0–1). Default 0.25 with ≥5 frames, 0.35 otherwise.
        public let extractionMinConfidence: Double
        /// Silence threshold (RMS) for noise calibration. Default 0.001 (-60dB).
        public let silenceThreshold: Float

        /// Creates a Configuration with custom parameters.
        public init(
            onsetMinGapMs: Double = 500,
            onsetEnergyMultiplier: Float = 2.0,
            onsetEnergyFloor: Float = 0.005,
            chromaWindowSize: Int = 8192,
            chromaHopSize: Int = 4096,
            earlyFrameAttackSkip: Int = 2,
            earlyFrameWindowSize: Int = 8,
            extractionMinConfidence: Double = 0.25,
            silenceThreshold: Float = 0.001
        ) {
            self.onsetMinGapMs = onsetMinGapMs
            self.onsetEnergyMultiplier = onsetEnergyMultiplier
            self.onsetEnergyFloor = onsetEnergyFloor
            self.chromaWindowSize = chromaWindowSize
            self.chromaHopSize = chromaHopSize
            self.earlyFrameAttackSkip = earlyFrameAttackSkip
            self.earlyFrameWindowSize = earlyFrameWindowSize
            self.extractionMinConfidence = extractionMinConfidence
            self.silenceThreshold = silenceThreshold
        }

        /// Default configuration.
        public static let `default` = Configuration()
    }

    // MARK: - Result

    /// Complete extraction result from audio analysis.
    public struct Result: Equatable, Hashable, Sendable {
        /// Detected chord segments in playback order.
        public let chordSegments: [ChordSegment]
        /// Inferred musical key from chord progression or pitch class distribution.
        public let key: MusicalKey?
        /// Melodic contour as a sequence of pitched note events with absolute timing.
        public let contour: [ContourNote]
        /// Individual detected notes (pre-contour, raw monophonic events).
        public let detectedNotes: [DetectedNote]
        /// Total duration of the analyzed buffer in seconds.
        public let duration: TimeInterval

        /// Creates an extraction result.
        public init(
            chordSegments: [ChordSegment],
            key: MusicalKey?,
            contour: [ContourNote],
            detectedNotes: [DetectedNote],
            duration: TimeInterval
        ) {
            self.chordSegments = chordSegments
            self.key = key
            self.contour = contour
            self.detectedNotes = detectedNotes
            self.duration = duration
        }
    }

    // MARK: - ChordSegment

    /// A detected chord segment with timing and confidence.
    public struct ChordSegment: Equatable, Hashable, Sendable, Identifiable {
        /// Unique identifier for this segment.
        public let id: UUID
        /// Onset time in seconds from buffer start.
        public let startTime: TimeInterval
        /// Offset time (end) in seconds from buffer start.
        public let endTime: TimeInterval
        /// Detected chord.
        public let chord: Chord
        /// Detection confidence (0.0–1.0).
        public let confidence: Double
        /// Which detection path produced this result (template matching, interval detection, multi-path agreement).
        public let detectionMethod: DetectionMethod

        /// Creates a chord segment.
        public init(
            id: UUID = UUID(),
            startTime: TimeInterval,
            endTime: TimeInterval,
            chord: Chord,
            confidence: Double,
            detectionMethod: DetectionMethod
        ) {
            self.id = id
            self.startTime = startTime
            self.endTime = endTime
            self.chord = chord
            self.confidence = confidence
            self.detectionMethod = detectionMethod
        }

        /// Chord detection method.
        public enum DetectionMethod: String, Equatable, Hashable, Sendable, CaseIterable {
            case classifier
            case interval
            case agreement
        }
    }

    // MARK: - Private helpers

    private static func deriveContour(from detectedNotes: [DetectedNote]) -> [ContourNote] {
        guard !detectedNotes.isEmpty else { return [] }

        var contour: [ContourNote] = []

        // First note: pitchSemitoneStep=0, parsonsCode=.repeat_
        contour.append(ContourNote(
            pitchSemitoneStep: 0,
            parsonsCode: .repeat_,
            onsetTime: detectedNotes[0].onsetTime,
            duration: detectedNotes[0].duration
        ))

        // Successive notes: difference MIDI values
        for i in 1..<detectedNotes.count {
            let step = detectedNotes[i].midiNote - detectedNotes[i - 1].midiNote
            let direction: ParsonsCode
            if step > 0 {
                direction = .up
            } else if step < 0 {
                direction = .down
            } else {
                direction = .repeat_
            }

            contour.append(ContourNote(
                pitchSemitoneStep: step,
                parsonsCode: direction,
                onsetTime: detectedNotes[i].onsetTime,
                duration: detectedNotes[i].duration
            ))
        }

        return contour
    }

    private static func inferKey(from chordSegments: [ChordSegment], fallbackNotes: [DetectedNote]) -> MusicalKey? {
        // First try: chord-based inference from segment progression
        if chordSegments.count >= 2 {
            let chords = chordSegments.map { $0.chord }
            let distinctChords = Set(chords)
            if distinctChords.count >= 2, let key = ProgressionAnalyzer.inferKey(from: chords) {
                return key
            }
        }

        // Fallback: pitch-class-based inference from detected notes
        if !fallbackNotes.isEmpty {
            let candidates = MelodyKeyInference.infer(from: fallbackNotes, maxCandidates: 1)
            return candidates.first?.key
        }

        return nil
    }
}
