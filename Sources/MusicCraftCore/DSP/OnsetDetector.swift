import Accelerate
import Foundation

/// Energy-based note onset detection.
///
/// Detects attack transients in an audio buffer using RMS energy thresholding against
/// a running average. Suitable for real-time and offline analysis of polyphonic and
/// monophonic audio.
public enum OnsetDetector {

    /// Detect note onsets in a PCM buffer using RMS-energy thresholding against a running average.
    ///
    /// Algorithm:
    /// - Splits the buffer into overlapping windows (default 2048-sample windows, 50% overlap)
    /// - Computes RMS energy for each window
    /// - Maintains a running average over the last N frames
    /// - Declares an onset when frame energy exceeds (running_avg × multiplier) AND exceeds absolute floor
    /// - Enforces a minimum time gap between successive onsets
    ///
    /// - Parameters:
    ///   - buffer: Mono Float32 PCM samples.
    ///   - sampleRate: Sample rate in Hz (typically 44100 or 48000).
    ///   - configuration: Tuning parameters. Defaults calibrated for typical attack detection.
    /// - Returns: Onset times in seconds from buffer start.
    public static func detectOnsets(
        buffer: [Float],
        sampleRate: Double,
        configuration: Configuration = .default
    ) -> [TimeInterval] {
        var onsets: [TimeInterval] = []

        let windowSize = configuration.windowSize
        let hopSize = configuration.hopSize
        let minGapSamples = Int(configuration.minGapMs / 1000.0 * sampleRate)
        let energyMultiplier = configuration.energyMultiplier
        let energyFloor = configuration.energyFloor
        let avgWindow = configuration.runningAverageWindow

        // Compute RMS energy for each window
        var energies: [(sample: Int, rms: Float)] = []
        var pos = 0

        while pos + windowSize <= buffer.count {
            var rms: Float = 0
            buffer.withUnsafeBufferPointer { ptr in
                vDSP_rmsqv(ptr.baseAddress! + pos, 1, &rms, vDSP_Length(windowSize))
            }
            energies.append((sample: pos, rms: rms))
            pos += hopSize
        }

        guard energies.count >= 2 else { return onsets }

        // Running average thresholding
        var lastOnsetSample = -minGapSamples  // Allow first onset at sample 0

        for i in 0..<energies.count {
            let start = max(0, i - avgWindow)
            let slice = energies[start..<i]
            let avg: Float = slice.isEmpty ? energies[i].rms : slice.map(\.rms).reduce(0, +) / Float(slice.count)
            let threshold = avg * energyMultiplier

            if energies[i].rms > threshold && energies[i].rms > energyFloor {
                let samplePos = energies[i].sample
                if samplePos - lastOnsetSample >= minGapSamples {
                    let time = Double(samplePos) / sampleRate
                    onsets.append(time)
                    lastOnsetSample = samplePos
                }
            }
        }

        return onsets
    }

    // MARK: - Configuration

    /// Tuning parameters for onset detection.
    public struct Configuration: Equatable, Hashable, Sendable {
        /// Window size in samples. Default 2048.
        public let windowSize: Int
        /// Hop size (overlap) in samples. Default 1024 (50% overlap).
        public let hopSize: Int
        /// Minimum gap between successive onsets in milliseconds. Default 500.
        public let minGapMs: Double
        /// Energy multiplier for running average threshold. Default 2.0.
        public let energyMultiplier: Float
        /// Absolute minimum RMS energy to declare an onset. Default 0.005.
        public let energyFloor: Float
        /// Number of previous frames to include in running average. Default 10.
        public let runningAverageWindow: Int

        /// Creates a Configuration with custom parameters.
        public init(
            windowSize: Int = 2048,
            hopSize: Int = 1024,
            minGapMs: Double = 500,
            energyMultiplier: Float = 2.0,
            energyFloor: Float = 0.005,
            runningAverageWindow: Int = 10
        ) {
            self.windowSize = windowSize
            self.hopSize = hopSize
            self.minGapMs = minGapMs
            self.energyMultiplier = energyMultiplier
            self.energyFloor = energyFloor
            self.runningAverageWindow = runningAverageWindow
        }

        /// Default configuration tuned for typical guitar/vocal attack detection.
        public static let `default` = Configuration()
    }
}
