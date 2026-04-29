import Foundation
import MusicCraftCore

/// Metrics for audio analysis quality evaluation, inspired by mir_eval's chord evaluation framework.
struct AudioAnalysisMetrics {
    // MARK: - Chord Detection Metrics

    struct ChordMetrics {
        /// Percentage of detected chords with correct root note.
        let rootAccuracy: Double

        /// Percentage of detected chords with correct quality (major, minor, 7th, etc.).
        let qualityAccuracy: Double

        /// Percentage of detected chords matching exactly (root + quality).
        let exactAccuracy: Double

        /// Mean confidence score across all detected chords.
        let confidenceAverage: Double

        /// Mean absolute time deviation (in seconds) between detected and ground truth chord boundaries.
        let timingDeviation: Double

        /// Count of chords detected where none existed (silence regions).
        let falsePositives: Int

        /// Count of chords missed (ground truth chord not detected).
        let falseNegatives: Int

        /// Total number of ground truth chords.
        let groundTruthCount: Int

        /// Total number of detected chords.
        let detectedCount: Int
    }

    /// Compare detected chords against ground truth using mir_eval-inspired metrics.
    /// Uses "majMin" reduction (major/minor distinction) and timing tolerance window.
    static func compareChords(
        detected: [MusicCraftCore.AudioExtractor.ChordSegment],
        groundTruth: [GroundTruth.ChordSegment],
        toleranceSeconds: TimeInterval = 0.2
    ) -> ChordMetrics {
        guard !groundTruth.isEmpty else {
            // If no ground truth, any detection is a false positive
            return ChordMetrics(
                rootAccuracy: 0.0,
                qualityAccuracy: 0.0,
                exactAccuracy: 0.0,
                confidenceAverage: detected.isEmpty ? 0.0 : detected.map { $0.confidence }.reduce(0, +) / Double(detected.count),
                timingDeviation: 0.0,
                falsePositives: detected.count,
                falseNegatives: 0,
                groundTruthCount: 0,
                detectedCount: detected.count
            )
        }

        var rootAccuracyCount = 0
        var qualityAccuracyCount = 0
        var exactAccuracyCount = 0
        var totalTimingDeviation = 0.0
        var matchedChords = 0
        var confidences: [Double] = []
        var falsePositives = 0

        // For each ground truth chord, find the best matching detected chord
        for gtChord in groundTruth {
            var bestMatch: (index: Int, score: Double)? = nil
            var bestTimingDeviation = Double.infinity

            for (i, detChord) in detected.enumerated() {
                // Check if timing overlaps (within tolerance)
                let timingOverlap = max(0.0, min(gtChord.endTime, detChord.endTime) - max(gtChord.startTime, detChord.startTime))

                if timingOverlap > toleranceSeconds {
                    // Timing match found. Now compare chord content.
                    let (rootMatch, qualityMatch) = compareChordContent(gtChord.chord, detChord.chord.displayName)

                    let timingDev = abs((detChord.startTime + detChord.endTime) / 2.0 - (gtChord.startTime + gtChord.endTime) / 2.0)

                    if rootMatch || qualityMatch {
                        // Keep the best match by timing deviation
                        if timingDev < bestTimingDeviation {
                            bestMatch = (i, Double(rootMatch ? 1 : 0) + Double(qualityMatch ? 1 : 0))
                            bestTimingDeviation = timingDev
                        }
                    }
                }
            }

            if let match = bestMatch {
                matchedChords += 1
                let detChord = detected[match.index]
                let (rootMatch, qualityMatch) = compareChordContent(gtChord.chord, detChord.chord.displayName)

                if rootMatch {
                    rootAccuracyCount += 1
                }
                if qualityMatch {
                    qualityAccuracyCount += 1
                }
                if rootMatch && qualityMatch {
                    exactAccuracyCount += 1
                }

                totalTimingDeviation += bestTimingDeviation
                confidences.append(detChord.confidence)
            }
        }

        let falseNegatives = groundTruth.count - matchedChords
        falsePositives = detected.count - matchedChords

        let rootAccuracy = matchedChords > 0 ? Double(rootAccuracyCount) / Double(matchedChords) : 0.0
        let qualityAccuracy = matchedChords > 0 ? Double(qualityAccuracyCount) / Double(matchedChords) : 0.0
        let exactAccuracy = matchedChords > 0 ? Double(exactAccuracyCount) / Double(matchedChords) : 0.0
        let confidenceAverage = confidences.isEmpty ? 0.0 : confidences.reduce(0, +) / Double(confidences.count)
        let timingDeviation = matchedChords > 0 ? totalTimingDeviation / Double(matchedChords) : 0.0

        return ChordMetrics(
            rootAccuracy: rootAccuracy,
            qualityAccuracy: qualityAccuracy,
            exactAccuracy: exactAccuracy,
            confidenceAverage: confidenceAverage,
            timingDeviation: timingDeviation,
            falsePositives: falsePositives,
            falseNegatives: falseNegatives,
            groundTruthCount: groundTruth.count,
            detectedCount: detected.count
        )
    }

    // MARK: - Tempo Metrics

    struct TempoMetrics {
        /// Percentage error between detected BPM and ground truth BPM.
        let tempoError: Double

        /// Mean confidence score from the tempo estimator.
        let confidenceScore: Double

        /// Position of the ground truth tempo in the ranked candidate list (1 = best).
        let rankedPosition: Int
    }

    /// Compare detected tempo against ground truth.
    static func compareTempo(
        detectedBPM: Int?,
        groundTruthBPM: Int
    ) -> TempoMetrics {
        guard let detected = detectedBPM else {
            return TempoMetrics(
                tempoError: 1.0,  // 100% error if no tempo detected
                confidenceScore: 0.0,
                rankedPosition: Int.max
            )
        }

        let error = Double(abs(detected - groundTruthBPM)) / Double(groundTruthBPM)

        return TempoMetrics(
            tempoError: error,
            confidenceScore: 0.0,  // Will be populated from actual estimator
            rankedPosition: 1  // Will be populated from actual ranker
        )
    }

    // MARK: - Note Detection Metrics

    struct NoteMetrics {
        /// Percentage of ground truth notes detected.
        let recall: Double

        /// Percentage of detected notes that are correct (no false positives).
        let precision: Double

        /// Percentage of detected notes within ±1 semitone of ground truth pitch.
        let pitchAccuracy: Double

        /// Percentage of detected note onsets within ±50ms of ground truth.
        let onsetAccuracy: Double
    }

    /// Compare detected notes against ground truth.
    static func compareNotes(
        detected: [MusicCraftCore.DetectedNote],
        groundTruth: [GroundTruth.NoteAnnotation],
        pitchToleranceSemitones: Int = 1,
        onsetToleranceSeconds: TimeInterval = 0.05
    ) -> NoteMetrics {
        guard !groundTruth.isEmpty else {
            return NoteMetrics(
                recall: 0.0,
                precision: detected.isEmpty ? 1.0 : 0.0,  // Perfect precision if no false positives
                pitchAccuracy: 0.0,
                onsetAccuracy: 0.0
            )
        }

        var detectedMatches = 0
        var pitchMatches = 0
        var onsetMatches = 0

        for gtNote in groundTruth {
            for detNote in detected {
                let onsetDiff = abs(detNote.onsetTime - gtNote.onsetTime)
                let pitchDiff = abs(detNote.midiNote - gtNote.midiNote)

                if onsetDiff <= onsetToleranceSeconds {
                    detectedMatches += 1

                    if pitchDiff <= pitchToleranceSemitones {
                        pitchMatches += 1
                    }

                    onsetMatches += 1
                    break
                }
            }
        }

        let recall = Double(detectedMatches) / Double(groundTruth.count)
        let precision = detected.isEmpty ? 1.0 : Double(detectedMatches) / Double(detected.count)
        let pitchAccuracy = detectedMatches > 0 ? Double(pitchMatches) / Double(detectedMatches) : 0.0
        let onsetAccuracy = detectedMatches > 0 ? Double(onsetMatches) / Double(detectedMatches) : 1.0

        return NoteMetrics(
            recall: recall,
            precision: precision,
            pitchAccuracy: pitchAccuracy,
            onsetAccuracy: onsetAccuracy
        )
    }

    // MARK: - Lyric Metrics

    struct LyricMetrics {
        /// Percentage of transcribed words matching ground truth (case-insensitive).
        let wordAccuracy: Double

        /// Character error rate (Levenshtein distance / total characters).
        let characterErrorRate: Double

        /// Percentage of word boundaries within ±100ms of ground truth.
        let timingAccuracy: Double

        /// Mean confidence per word.
        let confidenceAverage: Double
    }

    // MARK: - Helper: Chord Content Comparison

    /// Compare two chord names for root and quality match.
    /// Uses "majMin" reduction: distinguishes major/minor but treats quality subtleties as secondary.
    private static func compareChordContent(_ ground: String, _ detected: String) -> (rootMatch: Bool, qualityMatch: Bool) {
        let groundSimplified = normalizeChordName(ground)
        let detectedSimplified = normalizeChordName(detected)

        // Extract roots
        let groundRoot = String(groundSimplified.prefix(1))
        let detectedRoot = String(detectedSimplified.prefix(1))

        let rootMatch = groundRoot == detectedRoot

        // Extract quality (major/minor)
        let groundQuality = extractQuality(from: groundSimplified)
        let detectedQuality = extractQuality(from: detectedSimplified)

        let qualityMatch = groundQuality == detectedQuality

        return (rootMatch, qualityMatch)
    }

    /// Normalize chord name: remove octave designation, lowercase, handle sharps/flats.
    private static func normalizeChordName(_ name: String) -> String {
        let normalized = name
            .lowercased()
            .replacingOccurrences(of: "♯", with: "#")
            .replacingOccurrences(of: "♭", with: "b")
        return normalized
    }

    /// Extract quality from chord name ("major", "minor", "dim", "aug", "7", etc.).
    private static func extractQuality(from normalizedName: String) -> String {
        if normalizedName.contains("m") && !normalizedName.contains("maj") {
            return "minor"
        } else if normalizedName.contains("dim") {
            return "diminished"
        } else if normalizedName.contains("aug") {
            return "augmented"
        } else if normalizedName.contains("7") {
            return "dominant7"
        } else if normalizedName.contains("maj") {
            return "major"
        } else {
            return "major"  // Default to major if no quality indicator
        }
    }

    // MARK: - Progression Metrics (Phase 3 GuitarSet)

    struct ProgressionMetrics {
        /// Chord Symbol Recall at majMin vocabulary (root match only).
        /// Frame-weighted metric at 10ms resolution: matching_frames / total_non-N_annotated_frames.
        let majMinCSR: Double

        /// Mean absolute time deviation (in seconds) between chord segment boundaries.
        let medianTimingDeviationSec: TimeInterval

        /// Fraction of annotated time with no chord detected (no-chord regions).
        let noDetectionFraction: Double
    }

    /// Compare detected chord progression against ground truth GuitarSet data.
    /// Uses frame-by-frame comparison at 10ms resolution (standard for music analysis).
    /// CSR = Chord Symbol Recall (root match only, ignoring quality).
    static func compareProgression(
        detected: [MusicCraftCore.AudioExtractor.ChordSegment],
        groundTruth: [GroundTruth.ChordSegment],
        frameResolution: TimeInterval = 0.01  // 10ms
    ) -> ProgressionMetrics {
        guard !groundTruth.isEmpty else {
            return ProgressionMetrics(
                majMinCSR: 0.0,
                medianTimingDeviationSec: 0.0,
                noDetectionFraction: 0.0
            )
        }

        // Calculate total duration (from ground truth)
        let totalDuration = groundTruth.map { $0.duration }.reduce(0, +)
        let frameCount = Int(ceil(totalDuration / frameResolution))

        var matchingFrames = 0
        var annotatedFrames = 0
        var timingDeviations: [TimeInterval] = []

        // Frame-by-frame comparison
        for frameIdx in 0..<frameCount {
            let frameTime = TimeInterval(frameIdx) * frameResolution

            // Find ground truth chord at this time
            var gtChord: GroundTruth.ChordSegment? = nil
            for gtSeg in groundTruth {
                if gtSeg.startTime <= frameTime && frameTime < gtSeg.endTime {
                    gtChord = gtSeg
                    break
                }
            }

            if let gtChord = gtChord {
                annotatedFrames += 1

                // Find detected chord at this time
                var detChord: MusicCraftCore.AudioExtractor.ChordSegment? = nil
                for detSeg in detected {
                    if detSeg.startTime <= frameTime && frameTime < detSeg.endTime {
                        detChord = detSeg
                        break
                    }
                }

                if let detChord = detChord {
                    // Check for root match
                    let (rootMatch, _) = compareChordContent(gtChord.chord, detChord.chord.displayName)
                    if rootMatch {
                        matchingFrames += 1
                    }

                    // Track timing deviation for segment boundaries
                    let gtMid = (gtChord.startTime + gtChord.endTime) / 2.0
                    let detMid = (detChord.startTime + detChord.endTime) / 2.0
                    timingDeviations.append(abs(gtMid - detMid))
                }
            }
        }

        let csrValue = annotatedFrames > 0 ? Double(matchingFrames) / Double(annotatedFrames) : 0.0
        let medianTiming = timingDeviations.isEmpty ? 0.0 : {
            let sorted = timingDeviations.sorted()
            return sorted[sorted.count / 2]
        }()
        let noDetectionFrac = annotatedFrames > 0 ? Double(annotatedFrames - matchingFrames) / Double(annotatedFrames) : 0.0

        return ProgressionMetrics(
            majMinCSR: csrValue,
            medianTimingDeviationSec: medianTiming,
            noDetectionFraction: noDetectionFrac
        )
    }

    // MARK: - Extended Tempo Metrics (Phase 3 GuitarSet)

    struct TempoMetricsExtended {
        /// Percentage error between detected BPM and ground truth: |detected - gt| / gt
        let tempoError: Double

        /// Within ±5% of ground truth BPM
        let within5pct: Bool

        /// Within ±10% of ground truth BPM
        let within10pct: Bool

        /// Within ±20% of ground truth BPM
        let within20pct: Bool

        /// Detector reported approximately HALF the true tempo (common halftime error).
        /// True if abs(detected - 0.5*gt) / gt < 0.08
        let isHalftime: Bool

        /// Detector reported approximately DOUBLE the true tempo (common doubletime error).
        /// True if abs(detected - 2.0*gt) / gt < 0.08
        let isDoubletime: Bool
    }

    /// Compare detected tempo against ground truth with extended metrics for error modes.
    static func compareTempoExtended(
        detectedBPM: Double?,
        groundTruthBPM: Double
    ) -> TempoMetricsExtended {
        guard let detected = detectedBPM, detected > 0 else {
            return TempoMetricsExtended(
                tempoError: 1.0,
                within5pct: false,
                within10pct: false,
                within20pct: false,
                isHalftime: false,
                isDoubletime: false
            )
        }

        let error = abs(detected - groundTruthBPM) / groundTruthBPM

        let within5 = error <= 0.05
        let within10 = error <= 0.10
        let within20 = error <= 0.20

        // Halftime error: detected ≈ 0.5 × gt
        let halftimeError = abs(detected - 0.5 * groundTruthBPM) / groundTruthBPM
        let isHalftime = halftimeError < 0.08

        // Doubletime error: detected ≈ 2.0 × gt
        let doubletimeError = abs(detected - 2.0 * groundTruthBPM) / groundTruthBPM
        let isDoubletime = doubletimeError < 0.08

        return TempoMetricsExtended(
            tempoError: error,
            within5pct: within5,
            within10pct: within10,
            within20pct: within20,
            isHalftime: isHalftime,
            isDoubletime: isDoubletime
        )
    }

    // MARK: - Key Metrics (Phase 3 GuitarSet)

    struct KeyMetrics {
        /// Root and mode both correct (e.g., C major vs C major = true; C major vs A minor = false)
        let exactMatch: Bool

        /// Same pitch collection, allowing relative key (C major ↔ A minor)
        let relativeKeyMatch: Bool

        /// Correct root but wrong mode (e.g., C major vs C minor)
        let rootMatch: Bool

        /// The detected key (if any)
        let detectedKey: String?

        /// The ground truth key (from JAMS)
        let groundTruthKey: String
    }

    /// Compare detected key against ground truth (parsed from JAMS key_mode namespace).
    /// Ground truth JAMS format: "C:major", "A:minor", etc.
    static func compareKey(
        detected: MusicCraftCore.MusicalKey?,
        groundTruthJAMS: String
    ) -> KeyMetrics {
        let detectedStr = detected.map { key in
            let rootName: String
            switch key.root {
            case .C: rootName = "C"
            case .Cs: rootName = "C#"
            case .D: rootName = "D"
            case .Ds: rootName = "D#"
            case .E: rootName = "E"
            case .F: rootName = "F"
            case .Fs: rootName = "F#"
            case .G: rootName = "G"
            case .Gs: rootName = "G#"
            case .A: rootName = "A"
            case .As: rootName = "A#"
            case .B: rootName = "B"
            }

            let modeName: String
            switch key.mode {
            case .major: modeName = "major"
            case .minor: modeName = "minor"
            }

            return "\(rootName):\(modeName)"
        }

        // Parse ground truth JAMS key format: "C:major" or "A:minor"
        let gtParts = groundTruthJAMS.split(separator: ":")
        let gtRoot = gtParts.count > 0 ? String(gtParts[0]).lowercased() : "c"
        let gtMode = gtParts.count > 1 ? String(gtParts[1]).lowercased() : "major"

        // Check for exact match
        let exactMatch = detectedStr == groundTruthJAMS.lowercased()

        // Check for root match (same root, may differ in mode)
        let rootMatch: Bool = {
            guard let detStr = detectedStr else { return false }
            let detParts = detStr.split(separator: ":")
            return detParts.count > 0 && String(detParts[0]).lowercased() == gtRoot
        }()

        // Check for relative key match (same pitch collection)
        let relativeKeyMatch: Bool = {
            guard let detected = detected else { return exactMatch }

            // Relative keys: C major ↔ A minor, G major ↔ E minor, etc.
            // Relative minor is 3 semitones below the major (relative_minor_root = major_root - 3)
            let relativeKeyTable: [MusicCraftCore.NoteName: MusicCraftCore.NoteName] = [
                .C: .A,
                .Cs: .As,
                .D: .B,
                .Ds: .Cs,
                .E: .Cs,
                .F: .D,
                .Fs: .Ds,
                .G: .E,
                .Gs: .Fs,
                .A: .Fs,
                .As: .Gs,
                .B: .Gs,
            ]

            let detectedRootStr = detected.root.displayName.replacingOccurrences(of: "♯", with: "#").lowercased()

            // Same mode and same root
            if gtMode.contains("major") && detected.mode == .major {
                return detectedRootStr == gtRoot.lowercased()
            } else if gtMode.contains("minor") && detected.mode == .minor {
                return detectedRootStr == gtRoot.lowercased()
            } else if gtMode.contains("major") && detected.mode == .minor {
                // Detected minor is relative to gt major: check if detected.root is relative to gt.root
                if let relativeMinor = relativeKeyTable[detected.root],
                   relativeMinor.displayName.replacingOccurrences(of: "♯", with: "#").lowercased() == gtRoot.lowercased() {
                    return true
                }
            } else if gtMode.contains("minor") && detected.mode == .major {
                // Detected major is relative to gt minor: check if detected.root is relative major to gt.root
                // Reverse lookup: find which major key has gtRoot as its relative minor
                for (majorRoot, minorRoot) in relativeKeyTable {
                    if minorRoot.displayName.replacingOccurrences(of: "♯", with: "#").lowercased() == gtRoot.lowercased() && majorRoot == detected.root {
                        return true
                    }
                }
            }

            return false
        }()

        return KeyMetrics(
            exactMatch: exactMatch,
            relativeKeyMatch: relativeKeyMatch,
            rootMatch: rootMatch,
            detectedKey: detectedStr,
            groundTruthKey: groundTruthJAMS
        )
    }
}
