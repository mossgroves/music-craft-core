import Accelerate
import Foundation

/// Chroma-based chord detection using FFT spectral analysis.
///
/// Three-stage pipeline:
/// 1. **Template pre-filter** (weighted cosine similarity on 24 templates: 12 major + 12 minor)
/// 2. **Reference re-ranking** (Euclidean distance to reference chroma vectors via ChromaTemplateLibrary)
/// 3. **CoreML classifier** (optional, graceful fallback if unavailable)
///
/// Interval detector runs in parallel as a deterministic fallback. Multi-path agreement scoring
/// boosts confidence when classifier and interval detector agree on root+quality.
///
/// Noise baseline is calibrated from ~1s of silence at listening start, then subtracted from
/// each frame to reduce persistent microphone and electrical noise.
public final class ChordDetector: @unchecked Sendable {
    /// Detection result: a chord with confidence and the 12-element chroma vector for visualization.
    public struct Result {
        public let chord: Chord
        public let chroma: [Double] // 12-element chroma vector

        /// Public initializer to enable construction from external modules.
        public init(chord: Chord, chroma: [Double]) {
            self.chord = chord
            self.chroma = chroma
        }
    }

    private let sampleRate: Double
    private let bufferSize: Int

    // Required dependency injection
    private let chromaTemplateLibrary: ChromaTemplateLibrary
    private let classifierProvider: ChordClassifierProvider?

    // FFT setup
    private let log2n: vDSP_Length
    private let fftSetup: FFTSetup
    private let halfN: Int

    // Pre-allocated FFT buffers
    private var windowedBuffer: [Float]
    private var realPart: [Float]
    private var imagPart: [Float]
    private var magnitudes: [Float]
    private var window: [Float]

    // 24 weighted chord templates (12 major + 12 minor)
    // Weights: root=1.0, third=0.5, fifth=0.35
    private let templates: [(root: NoteName, quality: ChordQuality, chroma: [Double])]

    // Temporal smoothing
    private var previousChroma: [Double]?
    private let smoothingFactor: Double = 0.3

    // Noise baseline calibration and subtraction tuning
    private var noiseBaseline: [Double]?
    private var noiseBaselineTotal: Double = 0
    private var calibrationFrames: [[Double]] = []
    private let calibrationFrameCount = 10 // ~1860ms at 8192/44100
    private let silenceCalibrationThreshold: Double

    // Subtraction and gating thresholds (tuning knobs)
    private let subtractFloor: Double
    private let energyGateMultiplier: Double
    private let confidenceFallbackThreshold: Double
    private let agreementBoostFull: Double
    private let agreementBoostRootOnly: Double

    /// Verbose logging: gates high-volume diagnostic lines.
    /// Default off — enable for deep debugging sessions.
    public static var verboseLogging = false

    // One-shot diagnostic flag
    private var hasLoggedWindowCheck = false

    // Relative timestamp for detection logging (seconds since session start).
    public var sessionStartTime: CFAbsoluteTime = 0
    private var ts: String {
        let elapsed = CFAbsoluteTimeGetCurrent() - sessionStartTime
        return "[ts=\(String(format: "%.3f", elapsed))]"
    }

    // Last processed chroma (available even when detectChord returns nil)
    public private(set) var lastProcessedChroma: [Double]?

    // Noise baseline calibration state
    public var isNoiseBaselineCalibrated: Bool { noiseBaseline != nil }

    // Expose calibrated noise baseline for extraction pipeline
    public var calibratedNoiseBaseline: [Double]? { noiseBaseline }

    // Raw chroma before noise baseline subtraction for minor 3rd arbitration
    public private(set) var lastRawChroma: [Double]?

    // Overtone suppression: optional post-processing between chroma extraction and classifier
    public var useOvertoneSuppression: Bool = false
    public var overtoneSuppressionStrength: Double = 0.5

    /// Initialize a ChordDetector with required and optional dependencies.
    ///
    /// - Parameters:
    ///   - sampleRate: Audio sample rate (default 44100 Hz)
    ///   - bufferSize: FFT buffer size (default 8192 samples)
    ///   - chromaTemplateLibrary: Required library of chord chroma templates for distance matching
    ///   - classifierProvider: Optional CoreML classifier provider. If nil, pipeline degrades gracefully to template + interval matching
    ///   - silenceCalibrationThreshold: Chroma energy threshold for calibration frames (default 5.0). Only frames below this are used for baseline calibration.
    ///   - subtractFloor: Minimum subtraction floor for noise baseline (default 0.10). Prevents over-aggressive subtraction.
    ///   - energyGateMultiplier: Multiplier for energy gate threshold (default 0.5). Gate = baseline * multiplier.
    ///   - confidenceFallbackThreshold: Confidence score at which to trigger interval detector fallback (default 0.55)
    ///   - agreementBoostFull: Confidence boost when classifier and interval detector fully agree (default 0.10)
    ///   - agreementBoostRootOnly: Confidence boost when roots agree but qualities differ (default 0.05)
    public init(
        sampleRate: Double = 44100,
        bufferSize: Int = 8192,
        chromaTemplateLibrary: ChromaTemplateLibrary,
        classifierProvider: ChordClassifierProvider? = nil,
        silenceCalibrationThreshold: Double = 5.0,
        subtractFloor: Double = 0.10,
        energyGateMultiplier: Double = 0.5,
        confidenceFallbackThreshold: Double = 0.55,
        agreementBoostFull: Double = 0.10,
        agreementBoostRootOnly: Double = 0.05
    ) {
        self.sampleRate = sampleRate
        self.bufferSize = bufferSize
        self.chromaTemplateLibrary = chromaTemplateLibrary
        self.classifierProvider = classifierProvider
        self.halfN = bufferSize / 2

        self.silenceCalibrationThreshold = silenceCalibrationThreshold
        self.subtractFloor = subtractFloor
        self.energyGateMultiplier = energyGateMultiplier
        self.confidenceFallbackThreshold = confidenceFallbackThreshold
        self.agreementBoostFull = agreementBoostFull
        self.agreementBoostRootOnly = agreementBoostRootOnly

        let log2n = vDSP_Length(log2(Double(bufferSize)))
        self.log2n = log2n
        self.fftSetup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))!

        self.windowedBuffer = [Float](repeating: 0, count: bufferSize)
        self.realPart = [Float](repeating: 0, count: halfN)
        self.imagPart = [Float](repeating: 0, count: halfN)
        self.magnitudes = [Float](repeating: 0, count: halfN)
        self.window = DSPUtilities.hannWindow(length: bufferSize)

        // Generate 24 weighted templates (12 major + 12 minor)
        var templates: [(root: NoteName, quality: ChordQuality, chroma: [Double])] = []
        for root in NoteName.allCases {
            for quality in [ChordQuality.major, ChordQuality.minor] {
                var templateChroma = [Double](repeating: 0, count: 12)
                let rootIdx = root.rawValue
                let intervals = quality.intervals

                // Weight: root=1.0, third=0.5, fifth=0.35
                for interval in intervals {
                    let idx = (rootIdx + interval) % 12
                    if interval == 0 {
                        templateChroma[idx] = 1.0
                    } else if interval == 4 || interval == 3 {
                        templateChroma[idx] = 0.5
                    } else if interval == 7 {
                        templateChroma[idx] = 0.35
                    }
                }
                templates.append((root: root, quality: quality, chroma: templateChroma))
            }
        }
        self.templates = templates
    }

    deinit {
        vDSP_destroy_fftsetup(fftSetup)
    }

    /// Detect chord from a buffer of audio samples.
    /// Returns nil during the ~1s noise calibration period at listening start.
    public func detectChord(buffer: UnsafePointer<Float>, count: Int) -> Result? {
        let effectiveCount = min(count, bufferSize)
        guard effectiveCount == bufferSize else { return nil }

        // Step 1: Apply Hann window to reduce spectral leakage
        vDSP_vmul(buffer, 1, window, 1, &windowedBuffer, 1, vDSP_Length(bufferSize))

        // Step 2: FFT
        windowedBuffer.withUnsafeMutableBufferPointer { windowedPtr in
            realPart.withUnsafeMutableBufferPointer { realPtr in
                imagPart.withUnsafeMutableBufferPointer { imagPtr in
                    var split = DSPSplitComplex(
                        realp: realPtr.baseAddress!,
                        imagp: imagPtr.baseAddress!
                    )

                    vDSP_ctoz(
                        UnsafeRawPointer(windowedPtr.baseAddress!).assumingMemoryBound(to: DSPComplex.self),
                        2,
                        &split,
                        1,
                        vDSP_Length(halfN)
                    )

                    vDSP_fft_zip(fftSetup, &split, 1, log2n, FFTDirection(FFT_FORWARD))

                    // Compute magnitudes
                    for i in 0..<halfN {
                        let real = realPart[i]
                        let imag = imagPart[i]
                        magnitudes[i] = sqrt(real * real + imag * imag)
                    }
                }
            }
        }

        // Step 3: Extract chroma
        let rawChroma = extractChroma()
        lastRawChroma = rawChroma

        // Step 4: Calibrate noise baseline from silence frames
        if noiseBaseline == nil {
            let total = rawChroma.reduce(0, +)
            if total < silenceCalibrationThreshold {
                calibrationFrames.append(rawChroma)
                if calibrationFrames.count >= calibrationFrameCount {
                    // Compute median chroma across frames
                    var baseline = [Double](repeating: 0, count: 12)
                    for bin in 0..<12 {
                        let values = calibrationFrames.map { $0[bin] }.sorted()
                        baseline[bin] = values[values.count / 2]
                    }
                    noiseBaseline = baseline
                    noiseBaselineTotal = baseline.reduce(0, +)
                    print("\(ts)[NoiseGate] Calibrated baseline from \(calibrationFrames.count) frames, total=\(String(format: "%.2f", noiseBaselineTotal))")
                }
            }
            return nil // No detection during calibration
        }

        // Step 5: Subtract noise baseline
        var chroma = rawChroma
        if let baseline = noiseBaseline {
            for i in 0..<12 {
                let subtracted = chroma[i] - baseline[i]
                chroma[i] = max(0, min(subtracted, chroma[i])) // Clamp: can't go negative or exceed original
            }
            let floor = noiseBaselineTotal * subtractFloor
            for i in 0..<12 {
                if chroma[i] < floor {
                    chroma[i] = 0
                }
            }
        }

        // Step 6: Temporal smoothing
        if let prev = previousChroma {
            for i in 0..<12 {
                chroma[i] = chroma[i] * (1.0 - smoothingFactor) + prev[i] * smoothingFactor
            }
        }
        previousChroma = chroma
        lastProcessedChroma = chroma

        // Step 7: Suppress overtones if enabled
        if useOvertoneSuppression {
            chroma = suppressOvertones(chroma)
        }

        // Step 8: Identify bass root for harmonic/sympathetic suppression
        let bassRoot = identifyBassRoot()
        suppressHarmonicsAndSympathetic(&chroma, bassRoot: bassRoot)

        // Step 9: Energy gate
        let chromaTotal = chroma.reduce(0, +)
        if noiseBaseline != nil {
            let gate = noiseBaselineTotal * energyGateMultiplier
            if chromaTotal < gate {
                return nil
            }
        }

        // Step 10: Interval detector (deterministic fallback)
        let intervalResult = IntervalDetector.detect(chroma: chroma, rawChroma: rawChroma)

        // Step 11: Multi-path chord matching
        guard let match = matchChord(chroma: chroma, bassRoot: bassRoot) else {
            if let intervalResult {
                // If interval detector succeeded but classifier didn't, use interval result
                let notes = intervalResult.root.orderedNotesInChord(quality: intervalResult.quality)
                let chord = Chord(
                    root: intervalResult.root,
                    quality: intervalResult.quality,
                    confidence: intervalResult.confidence,
                    notes: notes,
                    timestamp: Date()
                )
                return Result(chord: chord, chroma: chroma)
            }
            return nil
        }

        // Step 12: Agreement scoring
        let finalScore: Double
        if let intervalResult {
            if intervalResult.root == match.root && intervalResult.quality == match.quality {
                finalScore = min(match.score + agreementBoostFull, 1.0)
            } else if intervalResult.root == match.root {
                finalScore = min(match.score + agreementBoostRootOnly, 1.0)
            } else {
                finalScore = match.score
            }
        } else {
            finalScore = match.score
        }

        let notes = match.root.orderedNotesInChord(quality: match.quality)
        let chord = Chord(
            root: match.root,
            quality: match.quality,
            confidence: min(finalScore, 1.0),
            notes: notes,
            timestamp: Date()
        )

        return Result(chord: chord, chroma: chroma)
    }

    /// Detect chord from a pre-computed chroma vector (for offline extraction).
    /// Skips FFT but applies all matching and agreement stages.
    public func detectChord(chroma: [Double]) -> Result? {
        guard chroma.count >= 12 else { return nil }

        var processedChroma = chroma
        lastProcessedChroma = processedChroma

        // Suppress overtones if enabled
        if useOvertoneSuppression {
            processedChroma = suppressOvertones(processedChroma)
        }

        // Identify bass root and suppress harmonics/sympathetic
        let bassRoot = identifyBassRoot(from: processedChroma)
        suppressHarmonicsAndSympathetic(&processedChroma, bassRoot: bassRoot)

        // Interval detector
        let intervalResult = IntervalDetector.detect(chroma: processedChroma, rawChroma: chroma)

        // Match
        guard let match = matchChord(chroma: processedChroma, bassRoot: bassRoot) else {
            if let intervalResult {
                let notes = intervalResult.root.orderedNotesInChord(quality: intervalResult.quality)
                let chord = Chord(
                    root: intervalResult.root,
                    quality: intervalResult.quality,
                    confidence: intervalResult.confidence,
                    notes: notes,
                    timestamp: Date()
                )
                return Result(chord: chord, chroma: processedChroma)
            }
            return nil
        }

        // Agreement scoring
        let finalScore: Double
        if let intervalResult {
            if intervalResult.root == match.root && intervalResult.quality == match.quality {
                finalScore = min(match.score + agreementBoostFull, 1.0)
            } else if intervalResult.root == match.root {
                finalScore = min(match.score + agreementBoostRootOnly, 1.0)
            } else {
                finalScore = match.score
            }
        } else {
            finalScore = match.score
        }

        let notes = match.root.orderedNotesInChord(quality: match.quality)
        let chord = Chord(
            root: match.root,
            quality: match.quality,
            confidence: min(finalScore, 1.0),
            notes: notes,
            timestamp: Date()
        )

        return Result(chord: chord, chroma: processedChroma)
    }

    /// Reset all state. Called when listening starts/stops or mode changes.
    public func reset() {
        previousChroma = nil
        noiseBaseline = nil
        noiseBaselineTotal = 0
        calibrationFrames = []
        hasLoggedWindowCheck = false
        lastProcessedChroma = nil
        lastRawChroma = nil
    }

    /// Clear only the noise baseline calibration, leaving other state intact.
    /// Used by extraction pipeline when a calibrated baseline is found to be contaminated.
    public func clearCalibration() {
        noiseBaseline = nil
        noiseBaselineTotal = 0
        calibrationFrames = []
    }

    // MARK: - Chroma Extraction

    private func extractChroma() -> [Double] {
        var chroma = [Double](repeating: 0, count: 12)
        let freqResolution = sampleRate / Double(bufferSize)

        // Range: ~65Hz to ~2000Hz covers most musical content
        let minBin = max(1, Int(65.0 / freqResolution))
        let maxBin = min(halfN - 1, Int(2000.0 / freqResolution))

        for bin in minBin...maxBin {
            let freq = Double(bin) * freqResolution
            let magnitude = Double(magnitudes[bin])

            guard magnitude > 0 && freq > 0 else { continue }

            let midiNote = 12.0 * log2(freq / 440.0) + 69.0  // A4 = 440Hz, MIDI 69
            let pitchClass = Int(round(midiNote)) % 12
            let normalizedClass = ((pitchClass % 12) + 12) % 12

            // 1/octave weighting: bass frequencies contribute more
            let octave = max(floor(midiNote / 12.0), 1.0)
            let octaveWeight = 1.0 / octave

            chroma[normalizedClass] += sqrt(magnitude) * octaveWeight
        }

        return chroma
    }

    // MARK: - Overtone Suppression

    private func suppressOvertones(_ chroma: [Double]) -> [Double] {
        let strength = overtoneSuppressionStrength
        guard strength > 0 else { return chroma }

        var suppressed = chroma

        let harmonics: [(semitones: Int, relativeAmplitude: Double)] = [
            (7, 0.40),   // 3rd harmonic (perfect 5th)
            (4, 0.20),   // 5th harmonic (major 3rd, 2 octaves up)
            (10, 0.10),  // 7th harmonic (minor 7th, 2 octaves up)
        ]

        for bin in 0..<12 {
            var overtoneContribution = 0.0

            for harmonic in harmonics {
                let fundamentalBin = ((bin - harmonic.semitones) % 12 + 12) % 12

                guard chroma[fundamentalBin] > chroma[bin] else { continue }

                overtoneContribution += chroma[fundamentalBin] * harmonic.relativeAmplitude
            }

            overtoneContribution = min(overtoneContribution, chroma[bin])
            suppressed[bin] = max(0, chroma[bin] - overtoneContribution * strength)
        }

        return suppressed
    }

    // MARK: - Harmonic & Sympathetic String Suppression

    private func suppressHarmonicsAndSympathetic(_ chroma: inout [Double], bassRoot: Int) {
        let rootEnergy = chroma[bassRoot]
        guard rootEnergy > 0.1 else { return }

        // 7th harmonic suppression: root + 10 semitones (minor 7th)
        let seventhBin = (bassRoot + 10) % 12
        let seventhOvertoneEstimate = rootEnergy * 0.15
        if chroma[seventhBin] < rootEnergy * 0.65 {
            chroma[seventhBin] = max(0, chroma[seventhBin] - seventhOvertoneEstimate)
        }

        // Sympathetic string suppression: standard guitar tuning E2-A2-D3-G3-B3-E4
        let openStringBins: Set<Int> = [4, 9, 2, 7, 11]  // E, A, D, G, B
        let sympatheticEstimate = rootEnergy * 0.10

        for bin in openStringBins {
            guard bin != bassRoot else { continue }
            guard chroma[bin] < rootEnergy * 0.70 else { continue }
            chroma[bin] = max(0, chroma[bin] - sympatheticEstimate)
        }
    }

    // MARK: - Bass Root Identification

    private func identifyBassRoot() -> Int {
        var bassEnergy = [Double](repeating: 0, count: 12)
        let freqResolution = sampleRate / Double(bufferSize)

        let minBin = max(1, Int(65.0 / freqResolution))
        let maxBin = min(halfN - 1, Int(200.0 / freqResolution))

        for bin in minBin...maxBin {
            let freq = Double(bin) * freqResolution
            let magnitude = Double(magnitudes[bin])
            guard magnitude > 0 && freq > 0 else { continue }

            let midiNote = 12.0 * log2(freq / 440.0) + 69.0
            let pitchClass = Int(round(midiNote)) % 12
            let normalizedClass = ((pitchClass % 12) + 12) % 12

            bassEnergy[normalizedClass] += sqrt(magnitude)
        }

        return bassEnergy.enumerated().max(by: { $0.element < $1.element })?.offset ?? 0
    }

    private func identifyBassRoot(from chroma: [Double]) -> Int {
        // For pre-computed chroma, return strongest bin as bass root
        return chroma.enumerated().max(by: { $0.element < $1.element })?.offset ?? 0
    }

    // MARK: - Stage 1: Template Pre-Filter

    private func templatePreFilter(chroma: [Double], bassRoot: Int) -> [(root: NoteName, quality: ChordQuality, score: Double)] {
        let totalEnergy = chroma.reduce(0, +)

        var candidates: [(root: NoteName, quality: ChordQuality, score: Double)] = []

        for template in templates {
            let score = scoreTemplate(template, chroma: chroma, bassRoot: bassRoot, totalEnergy: totalEnergy)
            candidates.append((root: template.root, quality: template.quality, score: score))
        }

        candidates.sort { $0.score > $1.score }
        return Array(candidates.prefix(5))
    }

    // MARK: - Stage 2: Reference Vector Re-ranking

    private func referenceRerank(
        candidates: [(root: NoteName, quality: ChordQuality, score: Double)],
        chroma: [Double]
    ) -> (root: NoteName, quality: ChordQuality, score: Double)? {
        guard !candidates.isEmpty else { return nil }
        guard candidates.first!.score > confidenceFallbackThreshold else { return nil }

        var reranked: [(root: NoteName, quality: ChordQuality, templateScore: Double, refDistance: Double)] = []

        for candidate in candidates {
            let name = candidate.root.displayName
                .replacingOccurrences(of: "♯", with: "#") + candidate.quality.shortSuffix
            let distance = chromaTemplateLibrary.distance(chroma, to: name)
            reranked.append((
                root: candidate.root,
                quality: candidate.quality,
                templateScore: candidate.score,
                refDistance: distance
            ))
        }

        var best: (root: NoteName, quality: ChordQuality, combinedScore: Double)?

        for item in reranked {
            let refScore = max(0, 1.0 - (item.refDistance / 2.0))
            let combined = item.templateScore * 0.4 + refScore * 0.6

            if best == nil || combined > best!.combinedScore {
                best = (root: item.root, quality: item.quality, combinedScore: combined)
            }
        }

        guard let winner = best, winner.combinedScore > 0.35 else { return nil }
        return (root: winner.root, quality: winner.quality, score: min(winner.combinedScore, 1.0))
    }

    // MARK: - Stage 3: Optional CoreML Classifier

    private func classifyChroma(_ chroma: [Double]) -> (name: String, confidence: Double)? {
        guard let provider = classifierProvider else { return nil }
        return provider.classifyChroma(chroma)
    }

    private func parseChordName(_ name: String) -> (root: NoteName, quality: ChordQuality)? {
        let root: NoteName
        let suffix: String
        if name.count >= 2 && name[name.index(after: name.startIndex)] == "#" {
            let rootStr = String(name.prefix(2))
            suffix = String(name.dropFirst(2))
            switch rootStr {
            case "C#": root = .Cs
            case "D#": root = .Ds
            case "F#": root = .Fs
            case "G#": root = .Gs
            case "A#": root = .As
            default: return nil
            }
        } else {
            let rootChar = name.first!
            suffix = String(name.dropFirst(1))
            switch rootChar {
            case "C": root = .C
            case "D": root = .D
            case "E": root = .E
            case "F": root = .F
            case "G": root = .G
            case "A": root = .A
            case "B": root = .B
            default: return nil
            }
        }

        let quality: ChordQuality
        switch suffix {
        case "": quality = .major
        case "m": quality = .minor
        case "7": quality = .dominant7
        case "maj7": quality = .major7
        case "m7": quality = .minor7
        case "sus2": quality = .sus2
        case "sus4": quality = .sus4
        case "aug": quality = .augmented
        case "m7b5": quality = .halfDiminished7
        case "dim7": quality = .diminished7
        default: quality = .major
        }

        return (root: root, quality: quality)
    }

    private func matchChord(chroma: [Double], bassRoot: Int) -> (root: NoteName, quality: ChordQuality, score: Double)? {
        // Stage 1: Template pre-filter
        let candidates = templatePreFilter(chroma: chroma, bassRoot: bassRoot)
        guard !candidates.isEmpty, candidates.first!.score > confidenceFallbackThreshold else { return nil }

        // Stage 3: Optional classifier
        let classifierResult = classifyChroma(chroma)

        // If classifier available, use three-stage scoring
        if let clf = classifierResult, let parsed = parseChordName(clf.name) {
            let clfRefDistance = chromaTemplateLibrary.distance(chroma, to: clf.name)
            let clfRefScore = max(0, 1.0 - (clfRefDistance / 2.0))

            let clfTemplateScore = candidates.first(where: {
                $0.root == parsed.root && $0.quality == parsed.quality
            })?.score ?? candidates.last?.score ?? 0

            let clfCombinedRaw = clfTemplateScore * 0.2 + clfRefScore * 0.3 + clf.confidence * 0.5
            let clfCombined = clfCombinedRaw * chromaScoreAdjustments(root: parsed.root, quality: parsed.quality, chroma: chroma)

            var bestCandidate: (root: NoteName, quality: ChordQuality, combined: Double)?
            for candidate in candidates {
                let name = candidate.root.displayName
                    .replacingOccurrences(of: "♯", with: "#") + candidate.quality.shortSuffix
                let refDist = chromaTemplateLibrary.distance(chroma, to: name)
                let refScore = max(0, 1.0 - (refDist / 2.0))

                let clfAgreement = (parsed.root == candidate.root && parsed.quality == candidate.quality)
                let clfScore = clfAgreement ? clf.confidence : 0.0

                let combinedRaw = candidate.score * 0.2 + refScore * 0.3 + clfScore * 0.5
                let combined = combinedRaw * chromaScoreAdjustments(root: candidate.root, quality: candidate.quality, chroma: chroma)

                if bestCandidate == nil || combined > bestCandidate!.combined {
                    bestCandidate = (root: candidate.root, quality: candidate.quality, combined: combined)
                }
            }

            if let best = bestCandidate {
                if clfCombined > best.combined {
                    return (root: parsed.root, quality: parsed.quality, score: min(clfCombined, 1.0))
                }
                return (root: best.root, quality: best.quality, score: min(best.combined, 1.0))
            }
        }

        // Fallback: use Stage 2 re-ranking
        if let reranked = referenceRerank(candidates: candidates, chroma: chroma) {
            return reranked
        }

        // Final fallback: return top Stage 1 candidate
        return candidates.first.map { (root: $0.root, quality: $0.quality, score: $0.score) }
    }

    private func chromaScoreAdjustments(root: NoteName, quality: ChordQuality, chroma: [Double]) -> Double {
        let rootBin = root.rawValue
        let intervals = quality.intervals
        var adjustment = 1.0

        // Penalty for missing chord tones
        var missingCount = 0
        for interval in intervals {
            let bin = (rootBin + interval) % 12
            if chroma[bin] < 0.05 {
                missingCount += 1
            }
        }

        if missingCount > 0 {
            adjustment *= max(0.5, 1.0 - Double(missingCount) * 0.15)
        }

        // Boost for strong root
        let rootEnergy = chroma[rootBin]
        adjustment *= (1.0 + 0.2 * min(rootEnergy, 1.0))

        return adjustment
    }

    private func scoreTemplate(_ template: (root: NoteName, quality: ChordQuality, chroma: [Double]), chroma: [Double], bassRoot: Int, totalEnergy: Double) -> Double {
        guard totalEnergy > 0 else { return 0 }

        // Cosine similarity
        var dotProduct = 0.0
        var templateMag = 0.0
        var chromaMag = 0.0

        for i in 0..<12 {
            dotProduct += template.chroma[i] * chroma[i]
            templateMag += template.chroma[i] * template.chroma[i]
            chromaMag += chroma[i] * chroma[i]
        }

        guard templateMag > 0 && chromaMag > 0 else { return 0 }

        var score = dotProduct / sqrt(templateMag * chromaMag)

        // Bass root boost: reward when template root matches bass root
        if template.root.rawValue == bassRoot {
            score *= 1.15
        }

        // Quality weighting
        let rootEnergy = chroma[template.root.rawValue]
        if template.quality == .major && rootEnergy > 0.3 {
            score *= 1.05
        }

        return max(0, min(score, 1.0))
    }
}

// MARK: - NoteName Extension for Note List Generation

private extension NoteName {
    func orderedNotesInChord(quality: ChordQuality) -> [NoteName] {
        let intervals = quality.intervals
        return intervals.compactMap { interval in
            NoteName(rawValue: (self.rawValue + interval) % 12)
        }
    }
}
