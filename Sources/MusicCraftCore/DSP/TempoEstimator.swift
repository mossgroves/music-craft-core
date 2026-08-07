import Accelerate
import Foundation

/// Tempo estimation from beat times or audio buffer.
/// Estimates one or more tempo candidates with confidence scores.
public enum TempoEstimator {
    /// Estimate tempo from beat times or from an audio buffer directly.
    /// If beats are provided, compute tempo from inter-beat intervals.
    /// If buffer is provided, detect onsets and estimate tempo from the onset strength signal.
    ///
    /// - Parameters:
    ///   - beats: Pre-detected beat times in seconds. If provided, buffer is ignored.
    ///   - buffer: Audio buffer (used if beats is nil).
    ///   - sampleRate: Sample rate (required if buffer is provided).
    ///   - configuration: Optional tuning.
    /// - Returns: Array of tempo candidates ranked by confidence. Empty if no tempos detected.
    public static func estimateTempo(
        beats: [TimeInterval]? = nil,
        buffer: [Float]? = nil,
        sampleRate: Double? = nil,
        configuration: Configuration = .default
    ) -> [TempoEstimate] {
        if let beats = beats, !beats.isEmpty {
            return estimateTempoFromBeats(beats: beats, configuration: configuration)
        }

        if let buffer = buffer, let sampleRate = sampleRate, !buffer.isEmpty {
            return estimateTempoFromBuffer(buffer: buffer, sampleRate: sampleRate, configuration: configuration)
        }

        return []
    }

    /// Tuning parameters for tempo estimation.
    public struct Configuration: Equatable, Hashable, Sendable {
        /// STFT window size (samples) for the spectral-flux onset detector used by the buffer path.
        /// Default lowered to 1024 in 0.0.11 to match per-frame onset granularity.
        public let onsetWindowSize: Int

        /// STFT hop size (samples) for the spectral-flux onset detector. Default 512 (50% overlap).
        public let onsetHopSize: Int

        /// Minimum inter-onset interval (ms) for the tempo histogram path. Default: 300 (~200 BPM).
        public let minTempoMs: Double

        /// Maximum inter-onset interval (ms) for the tempo histogram path. Default: 3000 (~20 BPM).
        public let maxTempoMs: Double

        /// Maximum number of tempo candidates to return. Default: 3.
        public let maxCandidates: Int

        /// Harmonic ratios used by the `estimateTempo(beats:)` JAMS-fed path (preserved for
        /// backward compatibility). The buffer path generates 2x and 0.5x octave candidates
        /// internally during histogram construction; this field is ignored on the buffer path.
        public let harmonicRatios: [Double]

        public init(
            onsetWindowSize: Int = 1024,
            onsetHopSize: Int = 512,
            minTempoMs: Double = 300,
            maxTempoMs: Double = 3000,
            maxCandidates: Int = 3,
            harmonicRatios: [Double] = [1, 2, 0.5, 1.5, 3, 0.33]
        ) {
            self.onsetWindowSize = onsetWindowSize
            self.onsetHopSize = onsetHopSize
            self.minTempoMs = minTempoMs
            self.maxTempoMs = maxTempoMs
            self.maxCandidates = maxCandidates
            self.harmonicRatios = harmonicRatios
        }

        public static let `default` = Configuration()
    }

    /// Estimate tempo from NOTE ONSETS — the note-native path (2026-07-21).
    ///
    /// Since 0.1.0 the engine is note-native (chords/key/contour all derive from Basic Pitch's
    /// note events); tempo was the last subsystem still fed by the spectral-flux front-end,
    /// whose known weakness on acoustic guitar is documented in TASKS (all five GuitarSet
    /// fixtures locked to 1/3 of ground truth; consumers saw mostly-abstaining tempo on real
    /// takes). Basic Pitch's onsets are far cleaner rhythmic evidence on guitar than raw flux —
    /// this entry feeds them into the SAME TempoHistogram the buffer path uses.
    ///
    /// One preparation step matters: **cluster collapsing.** A strummed chord is ONE rhythmic
    /// event played across many strings — its 3–6 note onsets land within a few tens of ms, and
    /// left as-is each would vote an absurd micro-IOI. Onsets within `clusterWindow` collapse to
    /// their first member before the histogram sees them (fingerpicked lines, whose notes spread
    /// wider than the window, pass through untouched).
    ///
    /// Returns [] below `minEvents` collapsed events — a handful of notes is not a pulse claim.
    ///
    /// CONFIDENCE SEMANTICS (the dead-axis root cause, measured 2026-07-21): the histogram's
    /// raw peak-mass share is structurally tiny — on PERFECT metronomic input it caps ≈0.22
    /// (each IOI's vote splits across octave bins and 3-bin smoothing), so a consumer gate
    /// calibrated to the beats path's regularity scale (~0.9 on steady input) could never pass.
    /// This path therefore reports **IOI consistency** instead: the fraction of collapsed
    /// inter-onset intervals that agree with the candidate's beat period at the 1x, 2x, or 0.5x
    /// level within ±8%. Steady playing → ~1.0; loose but real pulse → mid; rubato → low.
    /// Candidates are RANKED by that consistency too (histogram weight as tie-break), which
    /// demotes spurious near-miss peaks and sub-beat locks the raw histogram can rank first —
    /// the exact failure mode the flux path showed on GuitarSet (1/3-tempo lock).
    ///
    /// OCTAVE DISAMBIGUATION (2026-08-06, the "6 Human" double-time fix): consistency alone
    /// CANNOT choose between a tempo and its octave — the level sets of T and T/2 overlap
    /// almost completely. Measured on "6 Human" (felt ~80): ~47% of collapsed IOI mass sat
    /// on the SIXTEENTH grid (0.15–0.225s), whose out-of-range base rate (~320) the histogram
    /// folds once (0.5x, half-weight) into the 159–162 band — and a 0.25x fold is never
    /// generated, so ~79.5 could not even appear as a peak. The estimator reported 159, the
    /// 2x harmonic of the felt ~79.5. After the consistency ranking, the winner T is therefore
    /// re-litigated against T/2 and 2T via `disambiguateOctave` (comb support + strong-weak
    /// alternation evidence + a gentle log-Gaussian felt-tempo prior — see its doc comment).
    /// The reported primary is the disambiguated winner; its confidence is that winner's OWN
    /// IOI consistency, on the same scale as before, so the consumer's 0.3 display gate and
    /// the abstain posture are unchanged.
    public static func estimateTempo(
        noteOnsets: [TimeInterval],
        configuration: Configuration = .default,
        clusterWindow: TimeInterval = 0.05,
        minEvents: Int = 6
    ) -> [TempoEstimate] {
        let events = collapseClusters(noteOnsets.sorted(), window: clusterWindow)
        guard events.count >= minEvents else { return [] }

        let minBpm = max(40, Int((60_000.0 / configuration.maxTempoMs).rounded(.down)))
        let maxBpm = min(200, Int((60_000.0 / configuration.minTempoMs).rounded(.up)))

        // Wider smoothing than the buffer path (5 vs 3): human timing + Basic Pitch's ~11ms
        // onset quantization scatter votes across neighboring 1-BPM bins.
        let peaks = TempoHistogram.estimate(
            onsets: events,
            minBpm: minBpm,
            maxBpm: maxBpm,
            smoothingWindow: 5,
            maxCandidates: max(3, configuration.maxCandidates)
        )
        guard !peaks.isEmpty else { return [] }

        var iois: [TimeInterval] = []
        for i in 1..<events.count where events[i] - events[i - 1] > 0 {
            iois.append(events[i] - events[i - 1])
        }
        guard !iois.isEmpty else { return [] }

        /// Fraction of IOIs consistent with `bpm` at the beat, double, half, or quarter level
        /// (±8% — wide enough for human jitter, tight enough to reject near-miss tempi like
        /// 160 vs true 180). The quarter level (period/4) participates only when it clears
        /// `microIoiFloor` (2026-08-06, with the octave-disambiguation fix): a felt tempo's
        /// sixteenth grid is real pulse evidence — "6 Human" carries ~47% of its IOI mass
        /// there — but only for hypotheses slow enough that period/4 is musically plausible.
        /// The denominator stays ALL collapsed IOIs, so the confidence scale the consumer's
        /// 0.3 display gate was calibrated to is unchanged.
        func consistency(_ bpm: Double) -> Double {
            let period: Double = 60.0 / bpm
            var levels: [Double] = [period, period * 2.0, period * 0.5]
            if period * 0.25 >= microIoiFloor {
                levels.append(period * 0.25)
            }
            var matched = 0
            for ioi in iois {
                for level in levels where abs(ioi - level) <= 0.08 * level {
                    matched += 1
                    break
                }
            }
            return Double(matched) / Double(iois.count)
        }

        var scored: [(bpm: Double, consistency: Double, weight: Double)] = []
        for peak in peaks {
            scored.append((bpm: peak.bpm, consistency: consistency(peak.bpm), weight: peak.confidence))
        }
        scored.sort { a, b in
            a.consistency == b.consistency ? a.weight > b.weight : a.consistency > b.consistency
        }
        scored = Array(scored.prefix(configuration.maxCandidates))

        // Octave disambiguation (2026-08-06): the consistency ranking cannot separate T from
        // T/2 (their IOI level sets overlap), so the tie-break was silently the histogram's
        // preference for the raw subdivision rate — the double-time error. Re-score the winner
        // against its octave neighbors on evidence consistency CAN'T see: strong-weak
        // alternation and the felt-tempo prior.
        let rankedBpm = scored.first!.bpm
        let winnerBpm = disambiguateOctave(
            primaryBpm: rankedBpm,
            iois: iois,
            minBpm: Double(minBpm),
            maxBpm: Double(maxBpm)
        )

        // Rebuild the candidate list around the disambiguated winner. If the winner already
        // sits in the scored list (always true when nothing flipped; ±1.0 BPM absorbs the
        // histogram's integer bins vs. an exact T/2 like 79.5), promote that entry; otherwise
        // prepend the winner with its own freshly computed consistency. The displaced
        // candidates stay visible (isHarmonic marks octave relatives) — consumers see both
        // interpretations, ranked.
        var entries: [(bpm: Double, consistency: Double)]
        if let match = scored.first(where: { abs($0.bpm - winnerBpm) <= 1.0 }) {
            entries = [(match.bpm, match.consistency)]
                + scored.filter { $0.bpm != match.bpm }.map { ($0.bpm, $0.consistency) }
        } else {
            entries = [(winnerBpm, consistency(winnerBpm))]
                + scored.map { ($0.bpm, $0.consistency) }
        }
        entries = Array(entries.prefix(configuration.maxCandidates))

        let primaryBpm = entries.first!.bpm
        return entries.enumerated().map { idx, entry in
            let isHarmonic = idx > 0 && (
                abs(entry.bpm - primaryBpm * 2.0) < 1.5
                || abs(entry.bpm - primaryBpm * 0.5) < 1.5
            )
            return TempoEstimate(bpm: entry.bpm, confidence: entry.consistency, isHarmonic: isHarmonic)
        }
    }

    // MARK: - Octave disambiguation (2026-08-06)

    /// Choose between a winning tempo `T` and its octave neighbors `T/2` and `2T` — the
    /// standard MIR metrical-level problem. Field case: "6 Human" (felt ~80 BPM) read 159,
    /// the 2x harmonic of ~79.5, because its onsets are mostly eighth-note subdivisions and
    /// nothing downstream of the histogram ever asked whether the detected rate was the beat
    /// or the beat's subdivision.
    ///
    /// Each in-range hypothesis is scored `combSupport × beatPlausibility × perceptualPrior`
    /// (see `octaveScore`); the incumbent keeps ties, so a flip needs strictly better
    /// evidence. Returns the winning BPM unchanged in scale (e.g. 159 → 79.5, not re-binned).
    /// Internal for tests.
    static func disambiguateOctave(
        primaryBpm: Double,
        iois: [TimeInterval],
        minBpm: Double,
        maxBpm: Double
    ) -> Double {
        guard !iois.isEmpty else { return primaryBpm }
        var best = (bpm: primaryBpm, score: octaveScore(bpm: primaryBpm, iois: iois))
        for ratio in [0.5, 2.0] {
            let candidate = primaryBpm * ratio
            guard candidate >= minBpm, candidate <= maxBpm else { continue }
            let score = octaveScore(bpm: candidate, iois: iois)
            if score > best.score {
                best = (bpm: candidate, score: score)
            }
        }
        return best.bpm
    }

    /// IOIs shorter than this (>~428 BPM as a rate) are not pulse evidence for ANY felt
    /// tempo in the estimator's 40–200 range — the fastest musical sixteenth in range is
    /// 0.15s (200 BPM). Below the floor lives grace-note ornament, strum residue that
    /// escaped the 50ms cluster window, and Basic Pitch clutter on dense mixes ("6 Human"
    /// measured ~32% of its collapsed IOIs down there). The floor is applied SYMMETRICALLY
    /// (same filtered population for every hypothesis), and it also gates which hypotheses
    /// get a period/4 comb level: period/4 ≥ 0.14 ⇔ bpm ≤ ~107 — deep lattices belong to
    /// slow felt tempos; a fast hypothesis's "sixteenths" are sub-musical.
    static let microIoiFloor: TimeInterval = 0.14

    /// Weight of a subdivision-level IOI (period/2 or period/4) relative to a beat-level
    /// hit (1.0). The old implicit convention (0.5) double-counted a speed bias: the
    /// explicit perceptual prior ALREADY encodes "an ambiguous grid probably belongs to
    /// the slower felt tempo", so the comb itself should not lean as hard toward reading
    /// every grid as its own beat. 0.65 was tuned on the "6 Human" field case
    /// (2026-08-06) inside hard invariant bounds proven by the synthetic tests: it must
    /// stay BELOW prior(160)/prior(80) ≈ 0.777, or a dead-even 160 BPM beat train would
    /// flip to 80 on the prior alone.
    static let subdivisionBaseWeight: Double = 0.65

    /// Evidence score for one octave hypothesis, from collapsed IOIs alone.
    ///
    /// `combSupport` — how well the IOI comb supports this BPM as the BEAT, over the
    /// micro-floor-filtered population (see `microIoiFloor`):
    /// - IOI ≈ beat period → 1.0 (a beat-to-beat gap: direct, unshared evidence).
    /// - IOI ≈ half period → `subdivisionBaseWeight`, upgraded toward 1.0 by subdivision
    ///   ALTERNATION (below): even subdivisions are ambiguous (could be the beat of the
    ///   double tempo), but long-short alternating subdivisions are the signature of a
    ///   felt beat ABOVE them — swung/uneven eighths. This is the times-only proxy for
    ///   "onsets alternate strong-weak; every other onset is the real beat" (the
    ///   doubled-detection signature).
    /// - IOI ≈ quarter period (only when ≥ `microIoiFloor`) → `subdivisionBaseWeight`:
    ///   the felt tempo's sixteenth grid. This level is what lets a subdivision-dominated
    ///   take ("6 Human": ~47% of IOI mass at its felt-80 sixteenth) be claimed by the
    ///   felt tempo at all — the same mass reads as period/2 for the doubled hypothesis
    ///   and period/4 here, at EQUAL weight, so shared evidence cancels and the unshared
    ///   evidence plus the prior decide.
    /// - IOI ≈ double period → 0.5 (a skipped beat: real comb support, weaker than direct).
    ///
    /// `beatPlausibility` — mild penalty (×(1 − 0.25·A)) when this hypothesis's own
    /// beat-level IOIs alternate long-short: beats don't systematically alternate; a
    /// "beat" that swings is almost certainly a subdivision, so the hypothesis a level
    /// down should win. 0.25 keeps it a nudge, not a veto.
    ///
    /// `perceptualPrior` — gentle log-Gaussian on felt tempo (musicological standard:
    /// felt tempo concentrates in 60–120 BPM; Parncutt 1994-style resonance). Centered
    /// 95 BPM, σ = 1 octave: at 140 BPM the weight is still ≈0.86, so a genuinely fast
    /// song keeps winning on comb evidence — this is deliberately NOT a clamp. It only
    /// decides when comb evidence is close (e.g. eighths at 159 vs. the felt 79.5).
    /// Internal for tests.
    static func octaveScore(bpm: Double, iois: [TimeInterval], tolerance: Double = 0.08) -> Double {
        let population = iois.filter { $0 >= microIoiFloor }
        guard !population.isEmpty else { return 0 }
        let period = 60.0 / bpm
        let subdivisionAlternation = alternationStrength(iois: population, period: period / 2, tolerance: tolerance)
        let beatAlternation = alternationStrength(iois: population, period: period, tolerance: tolerance)
        let halfWeight = subdivisionBaseWeight + (1.0 - subdivisionBaseWeight) * subdivisionAlternation
        let quarterLevelActive = period * 0.25 >= microIoiFloor

        var support = 0.0
        for ioi in population {
            if abs(ioi - period) <= tolerance * period {
                support += 1.0
            } else if abs(ioi - period / 2) <= tolerance * (period / 2) {
                support += halfWeight
            } else if quarterLevelActive, abs(ioi - period / 4) <= tolerance * (period / 4) {
                support += subdivisionBaseWeight
            } else if abs(ioi - period * 2) <= tolerance * (period * 2) {
                support += 0.5
            }
        }
        let combSupport = support / Double(population.count)
        let beatPlausibility = 1.0 - 0.25 * beatAlternation
        return combSupport * beatPlausibility * perceptualPrior(bpm)
    }

    /// Gentle log-Gaussian felt-tempo prior. Center 95 BPM (the 60–120 felt-tempo band's
    /// log-center-ish), σ = 1 octave — wide enough that real fast/slow songs win on
    /// evidence: prior(140) ≈ 0.86, prior(160) ≈ 0.75, prior(80) ≈ 0.97. Never a clamp.
    /// Internal for tests.
    static func perceptualPrior(_ bpm: Double, center: Double = 95.0, sigmaOctaves: Double = 1.0) -> Double {
        guard bpm > 0 else { return 0 }
        let octaves = log2(bpm / center) / sigmaOctaves
        return exp(-0.5 * octaves * octaves)
    }

    /// Strength of long-short ALTERNATION among consecutive IOIs near `period`, in [0, 1].
    ///
    /// Measures the negative lag-1 autocorrelation of deviations from the matched IOIs' own
    /// mean: swung eighths (long, short, long, short…) → deviations alternate sign → ≈1;
    /// random human jitter → ≈0; a perfectly even train → zero variance → 0 (deliberate:
    /// an even train carries NO alternation evidence, so a genuine fast tempo is never
    /// demoted by this signal — only demonstrably uneven subdivisions are).
    ///
    /// Guards: ≥ 5 matched IOIs and ≥ 4 consecutive matched pairs before claiming anything
    /// (alternation from a handful of intervals is noise); variance ≥ 1e-9 s² rejects
    /// numerically-degenerate even trains.
    /// Internal for tests.
    static func alternationStrength(iois: [TimeInterval], period: Double, tolerance: Double = 0.08) -> Double {
        guard period > 0 else { return 0 }
        let tol = tolerance * period
        let matched = iois.indices.filter { abs(iois[$0] - period) <= tol }
        guard matched.count >= 5 else { return 0 }

        // Deviations are taken from the matched IOIs' own mean, not from `period`: the true
        // tempo rarely sits exactly on the hypothesis's (integer-binned) period, and a mean
        // offset would bias every deviation the same way, masking the alternation.
        let mean = matched.reduce(0.0) { $0 + iois[$1] } / Double(matched.count)

        let matchedSet = Set(matched)
        var crossSum = 0.0
        var squareSum = 0.0
        var pairCount = 0
        for i in matched where matchedSet.contains(i + 1) {
            let e0 = iois[i] - mean
            let e1 = iois[i + 1] - mean
            crossSum += e0 * e1
            squareSum += e0 * e0
            pairCount += 1
        }
        guard pairCount >= 4, squareSum > 1e-9 else { return 0 }
        return min(1.0, max(0.0, -crossSum / squareSum))
    }

    /// Collapse onsets that fall within `window` of the previous kept event into one (keeping
    /// the cluster's FIRST onset — the moment the gesture landed). Internal for tests.
    static func collapseClusters(_ sortedOnsets: [TimeInterval], window: TimeInterval) -> [TimeInterval] {
        guard !sortedOnsets.isEmpty else { return [] }
        var events: [TimeInterval] = [sortedOnsets[0]]
        for onset in sortedOnsets.dropFirst() where onset - events[events.count - 1] > window {
            events.append(onset)
        }
        return events
    }

    private static func estimateTempoFromBeats(beats: [TimeInterval], configuration: Configuration) -> [TempoEstimate] {
        guard beats.count >= 2 else { return [] }

        var interBeatIntervals: [TimeInterval] = []
        for i in 1..<beats.count {
            interBeatIntervals.append(beats[i] - beats[i - 1])
        }

        guard !interBeatIntervals.isEmpty else { return [] }

        let meanIbi = interBeatIntervals.reduce(0, +) / Double(interBeatIntervals.count)
        let variance = interBeatIntervals.map { pow($0 - meanIbi, 2) }.reduce(0, +) / Double(interBeatIntervals.count)
        let stdDev = sqrt(variance)
        let regularity = max(0, 1.0 - (stdDev / (meanIbi + 1e-10)))

        let meanBpm = 60.0 / meanIbi
        let baseTempoEstimate = TempoEstimate(bpm: meanBpm, confidence: regularity, isHarmonic: false)

        var allCandidates: [TempoEstimate] = [baseTempoEstimate]

        // Harmonics get a fixed octave-error penalty so they always rank below the base when
        // beats are reasonably regular. Prior 0.0.10 logic used `regularity * (1.0 / ratio)`,
        // which gave a 0.5x harmonic *twice* the confidence of the base and caused
        // half-tempo to be reported as primary on regular beat streams (Phase 3.2 GuitarSet
        // accuracy was 0% because of this — separate from the buffer-path 1/3-bug).
        let harmonicPenalty = 0.5
        for ratio in configuration.harmonicRatios {
            guard ratio > 0 else { continue }
            if abs(ratio - 1.0) < 1e-6 { continue }

            let harmonicBpm = meanBpm * ratio
            let harmonicConfidence = regularity * harmonicPenalty

            allCandidates.append(TempoEstimate(bpm: harmonicBpm, confidence: harmonicConfidence, isHarmonic: true))
        }

        return Array(allCandidates.sorted { $0.confidence > $1.confidence }.prefix(configuration.maxCandidates))
    }

    private static func estimateTempoFromBuffer(
        buffer: [Float],
        sampleRate: Double,
        configuration: Configuration
    ) -> [TempoEstimate] {
        let onsets = SpectralFluxOnsetDetector.detectOnsets(
            buffer: buffer,
            sampleRate: sampleRate,
            windowSize: configuration.onsetWindowSize,
            hopSize: configuration.onsetHopSize
        )

        let minBpm = max(40, Int((60_000.0 / configuration.maxTempoMs).rounded(.down)))
        let maxBpm = min(200, Int((60_000.0 / configuration.minTempoMs).rounded(.up)))

        let peaks = TempoHistogram.estimate(
            onsets: onsets,
            minBpm: minBpm,
            maxBpm: maxBpm,
            smoothingWindow: 3,
            maxCandidates: configuration.maxCandidates
        )

        guard !peaks.isEmpty else { return [] }
        let primaryBpm = peaks[0].bpm

        return peaks.enumerated().map { idx, peak in
            let isHarmonic = idx > 0 && (
                abs(peak.bpm - primaryBpm * 2.0) < 1.5
                || abs(peak.bpm - primaryBpm * 0.5) < 1.5
            )
            return TempoEstimate(bpm: peak.bpm, confidence: peak.confidence, isHarmonic: isHarmonic)
        }
    }
}
