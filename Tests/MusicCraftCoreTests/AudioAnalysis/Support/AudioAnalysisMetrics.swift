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
}
