import Accelerate
import Foundation

/// Beat detection via onset strength signal autocorrelation.
/// Stateless, pure function for detecting beat times in audio.
public enum BeatTracker {
    /// Detect beat times in an audio buffer using onset strength signal autocorrelation.
    /// Stateless, pure function.
    ///
    /// Algorithm: Compute RMS energy per frame (onset strength), autocorrelate to find periodic beat patterns,
    /// extract peaks above minAutocorrPeak threshold, apply inertia for stability.
    ///
    /// - Parameters:
    ///   - buffer: Mono Float32 PCM samples
    ///   - sampleRate: Sample rate in Hz
    ///   - configuration: Optional tuning for onset detection and beat induction
    /// - Returns: Array of beat times in seconds, sorted by time. Empty if no beats detected.
    public static func detectBeats(
        buffer: [Float],
        sampleRate: Double,
        configuration: Configuration = .default
    ) -> [TimeInterval] {
        guard !buffer.isEmpty else { return [] }

        let onsetStrength = computeOnsetStrengthSignal(
            buffer: buffer,
            windowSize: configuration.onsetWindowSize,
            hopSize: configuration.onsetHopSize
        )

        guard !onsetStrength.isEmpty else { return [] }

        let beatPeriodSamples = extractBeatPeriodFromAutocorrelation(
            onsetStrength: onsetStrength,
            sampleRate: sampleRate,
            configuration: configuration
        )

        guard beatPeriodSamples > 0 else { return [] }

        let beatTimes = extractBeatTimes(
            onsetStrength: onsetStrength,
            beatPeriodSamples: beatPeriodSamples,
            hopSize: configuration.onsetHopSize,
            sampleRate: sampleRate,
            configuration: configuration
        )

        return beatTimes
    }

    /// Tuning parameters for beat detection.
    public struct Configuration: Equatable, Hashable, Sendable {
        /// Onset detection window size (samples). Default: 2048.
        public let onsetWindowSize: Int

        /// Onset detection hop size (samples). Default: 1024 (50% overlap).
        public let onsetHopSize: Int

        /// Autocorrelation lag range minimum (ms). Default: 300 (~200 BPM).
        public let minBeatPeriodMs: Double

        /// Autocorrelation lag range maximum (ms). Default: 3000 (~20 BPM).
        public let maxBeatPeriodMs: Double

        /// Minimum autocorrelation peak height (normalized 0–1) to consider a period a beat candidate. Default: 0.3.
        public let minAutocorrPeak: Double

        /// Dynamical system coupling constant for beat induction (0–1, higher = more inertia). Default: 0.5.
        /// Higher values stabilize detected beats; lower values track tempo changes faster.
        public let inertia: Double

        public init(
            onsetWindowSize: Int = 2048,
            onsetHopSize: Int = 1024,
            minBeatPeriodMs: Double = 300,
            maxBeatPeriodMs: Double = 3000,
            minAutocorrPeak: Double = 0.3,
            inertia: Double = 0.5
        ) {
            self.onsetWindowSize = onsetWindowSize
            self.onsetHopSize = onsetHopSize
            self.minBeatPeriodMs = minBeatPeriodMs
            self.maxBeatPeriodMs = maxBeatPeriodMs
            self.minAutocorrPeak = minAutocorrPeak
            self.inertia = inertia
        }

        public static let `default` = Configuration()
    }

    private static func computeOnsetStrengthSignal(
        buffer: [Float],
        windowSize: Int,
        hopSize: Int
    ) -> [Float] {
        var onsetStrength: [Float] = []
        var frameIndex = 0

        while frameIndex + windowSize <= buffer.count {
            let frame = Array(buffer[frameIndex..<frameIndex + windowSize])

            var rms: Float = 0
            vDSP_rmsqv(frame, 1, &rms, vDSP_Length(frame.count))

            onsetStrength.append(rms)
            frameIndex += hopSize
        }

        return onsetStrength
    }

    private static func extractBeatPeriodFromAutocorrelation(
        onsetStrength: [Float],
        sampleRate: Double,
        configuration: Configuration
    ) -> Int {
        let maxLag = Int(configuration.maxBeatPeriodMs / 1000.0 * sampleRate / Double(configuration.onsetHopSize))
        let minLag = Int(configuration.minBeatPeriodMs / 1000.0 * sampleRate / Double(configuration.onsetHopSize))

        guard minLag > 0, maxLag < onsetStrength.count else { return 0 }

        // Compute autocorrelation manually for the lag range
        var maxValue: Float = 0
        var maxLagIndex = 0

        let lag0Correlation = computeAutocorrelation(onsetStrength, lag: 0)
        let normFactor = max(lag0Correlation, 1e-10)

        for lag in minLag...maxLag {
            let correlation = computeAutocorrelation(onsetStrength, lag: lag)
            let normalized = correlation / normFactor

            if normalized > maxValue && normalized > Float(configuration.minAutocorrPeak) {
                maxValue = normalized
                maxLagIndex = lag
            }
        }

        return maxLagIndex > 0 ? maxLagIndex : 0
    }

    private static func computeAutocorrelation(_ signal: [Float], lag: Int) -> Float {
        guard lag < signal.count else { return 0 }

        var correlation: Float = 0
        for i in 0..<(signal.count - lag) {
            correlation += signal[i] * signal[i + lag]
        }

        return correlation / Float(max(1, signal.count - lag))
    }

    private static func extractBeatTimes(
        onsetStrength: [Float],
        beatPeriodSamples: Int,
        hopSize: Int,
        sampleRate: Double,
        configuration: Configuration
    ) -> [TimeInterval] {
        var beatTimes: [TimeInterval] = []

        for (frameIndex, strength) in onsetStrength.enumerated() {
            if strength > 0.1 { // Threshold for onset detection
                let beatTime = TimeInterval(frameIndex) * TimeInterval(hopSize) / sampleRate
                beatTimes.append(beatTime)
            }
        }

        // Filter beats to match detected period
        guard !beatTimes.isEmpty, beatTimes.count > 1 else { return beatTimes }

        var filteredBeats: [TimeInterval] = [beatTimes[0]]
        let beatPeriodSeconds = TimeInterval(beatPeriodSamples) * TimeInterval(hopSize) / sampleRate

        for beatTime in beatTimes.dropFirst() {
            let timeSinceLastBeat = beatTime - filteredBeats.last!
            if abs(timeSinceLastBeat - beatPeriodSeconds) < beatPeriodSeconds * 0.3 {
                filteredBeats.append(beatTime)
            }
        }

        return filteredBeats
    }
}
