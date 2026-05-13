import Foundation

/// Histogram-based tempo estimation from a list of onset times.
///
/// Converts every consecutive inter-onset interval into BPM candidates (and their 2x/0.5x
/// octave variants), bins them at 1-BPM resolution, smooths the histogram, and returns the
/// top peaks ranked by histogram weight. Replaces the prior autocorrelation-of-RMS approach,
/// which was prone to locking onto sub-beat periodicities on percussive guitar audio.
///
/// Internal-only; consumed by TempoEstimator's buffer path.
enum TempoHistogram {
    /// One ranked BPM candidate.
    struct Peak {
        let bpm: Double
        /// Fraction of total histogram evidence at this BPM bin. In `[0, 1]`.
        let confidence: Double
    }

    /// Build a tempo histogram from onset times and return the top peaks.
    ///
    /// - Parameters:
    ///   - onsets: Onset times in seconds, ascending.
    ///   - minBpm: Lower bound for histogram bins (inclusive). Default 40.
    ///   - maxBpm: Upper bound for histogram bins (inclusive). Default 200.
    ///   - smoothingWindow: Size of the moving-average window applied to the histogram. Default 3.
    ///   - maxCandidates: Maximum number of peaks to return. Default 3.
    /// - Returns: Peaks ranked by histogram weight, descending. Empty if fewer than 2 onsets.
    static func estimate(
        onsets: [TimeInterval],
        minBpm: Int = 40,
        maxBpm: Int = 200,
        smoothingWindow: Int = 3,
        maxCandidates: Int = 3
    ) -> [Peak] {
        guard onsets.count >= 2, minBpm < maxBpm else { return [] }

        let binCount = maxBpm - minBpm + 1
        var histogram = [Double](repeating: 0, count: binCount)

        for i in 1..<onsets.count {
            let ioi = onsets[i] - onsets[i - 1]
            guard ioi > 0 else { continue }
            let base = 60.0 / ioi

            // Primary BPM gets full weight; 2x and 0.5x octave variants get half-weight so
            // the histogram preserves the IOI-derived rate when the audio is unambiguous and
            // still surfaces octave alternatives for ambiguous material.
            let candidates: [(bpm: Double, weight: Double)] = [
                (base, 1.0),
                (base * 2.0, 0.5),
                (base * 0.5, 0.5)
            ]

            for entry in candidates {
                guard entry.bpm.isFinite else { continue }
                let bin = Int(entry.bpm.rounded()) - minBpm
                guard bin >= 0, bin < binCount else { continue }
                histogram[bin] += entry.weight
            }
        }

        // 3-bin moving-average smoothing.
        let smoothed: [Double]
        if smoothingWindow > 1 {
            let half = smoothingWindow / 2
            var result = [Double](repeating: 0, count: binCount)
            for i in 0..<binCount {
                let lo = max(0, i - half)
                let hi = min(binCount - 1, i + half)
                var sum = 0.0
                for j in lo...hi { sum += histogram[j] }
                result[i] = sum / Double(hi - lo + 1)
            }
            smoothed = result
        } else {
            smoothed = histogram
        }

        let totalWeight = smoothed.reduce(0, +)
        guard totalWeight > 0 else { return [] }

        // Find local-maximum bins.
        var peakBins: [(bin: Int, weight: Double)] = []
        for i in 0..<binCount {
            let weight = smoothed[i]
            guard weight > 0 else { continue }
            let leftOK = i == 0 || smoothed[i - 1] <= weight
            let rightOK = i == binCount - 1 || smoothed[i + 1] <= weight
            if leftOK && rightOK {
                peakBins.append((bin: i, weight: weight))
            }
        }

        peakBins.sort { $0.weight > $1.weight }

        let topPeaks = peakBins.prefix(maxCandidates).map { entry in
            Peak(
                bpm: Double(entry.bin + minBpm),
                confidence: entry.weight / totalWeight
            )
        }

        return Array(topPeaks)
    }
}
