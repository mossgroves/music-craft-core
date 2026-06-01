import Foundation

/// Offline audio analysis pipeline producing chord progressions, key, contour, and detected notes from a PCM buffer.
///
/// AudioExtractor composes DSP primitives (OnsetDetector, NoiseCalibrator, PitchDetector, ChromaExtractor),
/// chord detection (ChordDetector), and music theory inference (ProgressionAnalyzer, MelodyKeyInference)
/// to analyze a complete audio buffer and return comprehensive musical descriptors.
///
/// **Key inference strategy:**
/// 1. If chord segments produce a usable progression (≥2 distinct chords), use ProgressionAnalyzer.inferKey (chord-based).
/// 2. Else if detected notes are populated, use MelodyKeyInference.infer (pitch-class-based) and take the top candidate's key.
/// 3. Else Result.key is nil.
///
/// This two-path approach leverages the strongest signal available: chord progressions when the audio contains
/// harmonic content, pitch class distributions when it contains melody only.
///
/// **Note source:** `Configuration.noteSource` selects the front-end. `.dsp` (default) is the pipeline described
/// above. `.basicPitch` derives the same `Result` from a bundled Basic Pitch Core ML transcription + note-native
/// chords (full-polyphony key via chords, a skyline melodic reduction for `detectedNotes`/`contour`); the `Result`
/// shape is identical, so callers need no change.
///
/// **Pure function:** the `.dsp` path does no I/O, no async, no AVFoundation — all input is a PCM buffer, all output
/// typed Swift values. The `.basicPitch` path loads a bundled Core ML model the first time it runs (once,
/// process-wide), so the "no I/O" property holds only for `.dsp`.
public enum AudioExtractor {

    /// Extract chord segments, key, melodic contour, and detected notes from an audio buffer.
    ///
    /// - Parameters:
    ///   - buffer: Mono Float32 PCM samples.
    ///   - sampleRate: Sample rate in Hz (typically 44100 or 48000).
    ///   - configuration: Optional tuning. Defaults are calibrated for Cantus's nylon-string and Sanctuary's vocal/instrumental capture.
    /// - Returns: Bundled extraction result.
    public static func extract(
        buffer: [Float],
        sampleRate: Double,
        configuration: Configuration = .default
    ) -> Result {
        // Note-source switch (additive; default .dsp). The .basicPitch path uses Basic Pitch
        // transcription + note-native chords; the .dsp path below is the original pipeline, verbatim.
        if configuration.noteSource == .basicPitch {
            return extractViaBasicPitch(buffer: buffer, sampleRate: sampleRate, configuration: configuration)
        }

        // Calibrate noise baseline from silence frames
        let noiseBaseline = NoiseCalibrator.calibrateBaseline(
            buffer: buffer,
            sampleRate: sampleRate,
            windowSize: configuration.chromaWindowSize,
            hopSize: configuration.chromaHopSize,
            silenceThreshold: configuration.silenceThreshold
        )

        // Detect onsets
        let onsets = OnsetDetector.detectOnsets(
            buffer: buffer,
            sampleRate: sampleRate,
            configuration: OnsetDetector.Configuration(
                windowSize: configuration.chromaWindowSize,
                hopSize: configuration.chromaHopSize,
                minGapMs: configuration.onsetMinGapMs,
                energyMultiplier: configuration.onsetEnergyMultiplier,
                energyFloor: configuration.onsetEnergyFloor
            )
        )

        // Extract chords from segments
        let chordSegments = extractChordSegments(
            buffer: buffer,
            sampleRate: sampleRate,
            onsets: onsets,
            noiseBaseline: noiseBaseline,
            configuration: configuration
        )

        // Detect pitch track and segment into notes
        let detectedNotes = detectNotes(
            buffer: buffer,
            sampleRate: sampleRate,
            onsets: onsets,
            configuration: configuration
        )

        // Derive contour from detected notes
        let contour = deriveContour(from: detectedNotes)

        // Infer key: chord-based first, fallback to pitch-class-based
        let key = inferKey(from: chordSegments, fallbackNotes: detectedNotes)

        let duration = TimeInterval(buffer.count) / sampleRate

        return Result(
            chordSegments: chordSegments,
            key: key,
            contour: contour,
            detectedNotes: detectedNotes,
            duration: duration
        )
    }

    // MARK: - Basic Pitch note source

    /// Process-wide cached Basic Pitch transcriber. A Swift `static let` is initialized exactly once
    /// (lazily, thread-safe), so the bundled Core ML model is compiled + loaded a single time and
    /// reused across every `extract(.basicPitch)` call — no per-call recompile. `nil` if the model
    /// can't load (the `.basicPitch` path then degrades to a well-formed empty Result; default is `.dsp`).
    private static let sharedBasicPitchTranscriber: BasicPitchTranscriber? = try? BasicPitchTranscriber()

    /// `.basicPitch` path: transcribe once, then derive every `Result` field, reusing the existing
    /// `deriveContour` / `inferKey` / `Result` machinery. `Result` shape is identical to `.dsp`.
    private static func extractViaBasicPitch(buffer: [Float], sampleRate: Double, configuration: Configuration) -> Result {
        let duration = TimeInterval(buffer.count) / sampleRate
        guard let transcriber = sharedBasicPitchTranscriber,
              let transcription = try? transcriber.transcribe(buffer, sampleRate: sampleRate) else {
            // Model unavailable → never crash; emit a well-formed empty Result.
            return Result(chordSegments: [], key: nil, contour: [], detectedNotes: [], duration: duration)
        }
        let notes = transcription.notes
        let chordSegments = noteNativeChordSegments(notes: notes, duration: duration)   // FULL polyphony → note-native (the validated win)
        let detectedNotes = skyline(of: notes)                                          // monophonic melodic reduction
        let contour = deriveContour(from: detectedNotes)                                // REUSE existing contour
        let key = inferKey(from: chordSegments, fallbackNotes: detectedNotes)           // REUSE existing key inference (chord-based first)
        return Result(chordSegments: chordSegments, key: key, contour: contour, detectedNotes: detectedNotes, duration: duration)
    }

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

    /// Selects the note/chord front-end for `extract`. `.dsp` (default) is the original
    /// YIN + FFT-chroma pipeline; `.basicPitch` uses the bundled Basic Pitch model + note-native chords.
    public enum NoteSource: String, Equatable, Hashable, Sendable, CaseIterable {
        case dsp          // current YIN + FFT-chroma path (default)
        case basicPitch   // Basic Pitch transcription + note-native chords
    }

    /// Tuning parameters for audio extraction.
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
        /// Note/chord front-end. Default `.dsp` (current behavior — flipping to `.basicPitch` is opt-in).
        public let noteSource: NoteSource

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
            silenceThreshold: Float = 0.001,
            noteSource: NoteSource = .dsp
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
            self.noteSource = noteSource
        }

        /// Default configuration tuned for Cantus's guitar capture.
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

    private static func extractChordSegments(
        buffer: [Float],
        sampleRate: Double,
        onsets: [TimeInterval],
        noiseBaseline: NoiseBaseline?,
        configuration: Configuration
    ) -> [ChordSegment] {
        // Build segments from onsets
        guard !onsets.isEmpty else { return [] }

        var segments: [ChordSegment] = []
        let chromaExtractor = ChromaExtractor(bufferSize: configuration.chromaWindowSize, sampleRate: sampleRate)
        let chordDetector = ChordDetector(sampleRate: sampleRate, bufferSize: configuration.chromaWindowSize, chromaTemplateLibrary: CanonicalChromaLibrary())

        for i in 0..<onsets.count {
            let startSample = Int(onsets[i] * sampleRate)
            let endSample: Int
            if i + 1 < onsets.count {
                endSample = Int(onsets[i + 1] * sampleRate)
            } else {
                endSample = buffer.count
            }

            // Minimum segment length check
            guard endSample - startSample >= configuration.chromaWindowSize else { continue }

            // Extract chroma with early-frame windowing and averaging
            var chromas: [[Double]] = []
            var pos = startSample + (configuration.earlyFrameAttackSkip * configuration.chromaHopSize)

            while pos + configuration.chromaWindowSize <= endSample && chromas.count < configuration.earlyFrameWindowSize {
                let slice = Array(buffer[pos..<(pos + configuration.chromaWindowSize)])
                var chroma = slice.withUnsafeBufferPointer { ptr in
                    chromaExtractor.extractChroma(buffer: UnsafeMutablePointer(mutating: ptr.baseAddress!), count: configuration.chromaWindowSize)
                }

                // Subtract noise baseline if available
                if let baseline = noiseBaseline {
                    for j in 0..<12 {
                        chroma[j] = max(0, chroma[j] - baseline.chroma[j])
                    }
                }

                chromas.append(chroma)
                pos += configuration.chromaHopSize
            }

            guard !chromas.isEmpty else { continue }

            // Average chroma vectors
            var avgChroma = [Double](repeating: 0, count: 12)
            for chroma in chromas {
                for j in 0..<12 {
                    avgChroma[j] += chroma[j]
                }
            }
            for j in 0..<12 {
                avgChroma[j] /= Double(chromas.count)
            }

            // Detect chord
            guard let result = chordDetector.detectChord(chroma: avgChroma) else { continue }

            // Check minimum confidence threshold
            let minConfidence = chromas.count >= 5 ? configuration.extractionMinConfidence : 0.35

            if result.chord.confidence >= minConfidence {
                segments.append(ChordSegment(
                    startTime: onsets[i],
                    endTime: i + 1 < onsets.count ? onsets[i + 1] : TimeInterval(buffer.count) / sampleRate,
                    chord: result.chord,
                    confidence: result.chord.confidence,
                    detectionMethod: .classifier
                ))
            }
        }

        return segments
    }

    private static func detectNotes(
        buffer: [Float],
        sampleRate: Double,
        onsets: [TimeInterval],
        configuration: Configuration
    ) -> [DetectedNote] {
        // Run pitch detector on the entire buffer
        let pitchDetector = PitchDetector(sampleRate: sampleRate, bufferSize: 4096, threshold: 0.1)
        var frameNotes: [(frame: Int, pitch: Double, confidence: Double)] = []

        var pos = 0
        while pos + 4096 <= buffer.count {
            let slice = Array(buffer[pos..<(pos + 4096)])
            let result = slice.withUnsafeBufferPointer { ptr in
                pitchDetector.detectPitch(buffer: UnsafeMutablePointer(mutating: ptr.baseAddress!), count: 4096)
            }

            if let result = result, result.confidence > 0.1 {
                frameNotes.append((frame: pos, pitch: result.frequency, confidence: result.confidence))
            }

            pos += 2048  // 50% overlap
        }

        guard !frameNotes.isEmpty else { return [] }

        // Segment frame notes into detected note events using onset boundaries
        var detectedNotes: [DetectedNote] = []

        for i in 0..<onsets.count {
            let onsetSample = Int(onsets[i] * sampleRate)
            let nextOnsetSample = i + 1 < onsets.count ? Int(onsets[i + 1] * sampleRate) : buffer.count

            // Find stable pitch within this onset-bounded region
            let regionNotes = frameNotes.filter { $0.frame >= onsetSample && $0.frame < nextOnsetSample }
            guard !regionNotes.isEmpty else { continue }

            // Take the most frequent pitch in this region
            var pitchCounts: [Double: (count: Int, confidence: Double)] = [:]
            for note in regionNotes {
                let roundedPitch = (note.pitch * 2).rounded() / 2  // Quantize to 50-cent bins
                if pitchCounts[roundedPitch] == nil {
                    pitchCounts[roundedPitch] = (count: 0, confidence: 0)
                }
                pitchCounts[roundedPitch]!.count += 1
                pitchCounts[roundedPitch]!.confidence = note.confidence
            }

            guard let (frequency, data) = pitchCounts.max(by: { $0.value.count < $1.value.count }) else { continue }

            // Convert frequency to MIDI note
            let midiNote = Int(round(12 * (log2(frequency / 440.0) + 4.75)))
            guard midiNote >= 0 && midiNote <= 127 else { continue }

            let onsetTime = onsets[i]
            let duration = TimeInterval(nextOnsetSample - onsetSample) / sampleRate

            detectedNotes.append(DetectedNote(
                midiNote: midiNote,
                onsetTime: onsetTime,
                duration: duration,
                confidence: data.confidence
            ))
        }

        return detectedNotes
    }

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
