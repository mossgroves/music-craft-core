import Foundation

/// Beat detection backed by spectral-flux onset detection (0.0.11).
/// Stateless, pure function for detecting beat times in audio.
public enum BeatTracker {
    /// Detect beat times in an audio buffer.
    ///
    /// 0.0.11: backed by `SpectralFluxOnsetDetector` (Dixon 2006 half-wave-rectified spectral flux
    /// with adaptive median thresholding and minimum-gap peak picking). The previous
    /// RMS-energy autocorrelation algorithm produced 0% accuracy with systematic 1/3-tempo
    /// error on real guitar audio. Returned values are onset times; on rhythmically clear
    /// material these align with beat positions, on free-rhythm material they reflect
    /// articulation events.
    ///
    /// - Parameters:
    ///   - buffer: Mono Float32 PCM samples.
    ///   - sampleRate: Sample rate in Hz.
    ///   - configuration: Optional tuning (window/hop sizes); other fields are accepted for
    ///     backward compatibility but no longer drive an autocorrelation step.
    /// - Returns: Array of beat times in seconds, sorted ascending. Empty if no beats detected.
    public static func detectBeats(
        buffer: [Float],
        sampleRate: Double,
        configuration: Configuration = .default
    ) -> [TimeInterval] {
        guard !buffer.isEmpty else { return [] }

        return SpectralFluxOnsetDetector.detectOnsets(
            buffer: buffer,
            sampleRate: sampleRate,
            windowSize: configuration.onsetWindowSize,
            hopSize: configuration.onsetHopSize
        )
    }

    /// Tuning parameters for beat detection.
    public struct Configuration: Equatable, Hashable, Sendable {
        /// STFT window size (samples) for the spectral-flux onset detector. Default 1024.
        public let onsetWindowSize: Int

        /// STFT hop size (samples). Default 512 (50% overlap).
        public let onsetHopSize: Int

        /// Lower bound (ms) for inter-beat intervals retained downstream. Default 300 (~200 BPM).
        /// 0.0.11: informational; the spectral-flux detector enforces its own 50ms minimum gap.
        public let minBeatPeriodMs: Double

        /// Upper bound (ms) for inter-beat intervals retained downstream. Default 3000 (~20 BPM).
        public let maxBeatPeriodMs: Double

        /// Retained for backward compatibility; not consulted by the spectral-flux pipeline.
        public let minAutocorrPeak: Double

        /// Retained for backward compatibility; reserved for future beat-tracking work.
        public let inertia: Double

        public init(
            onsetWindowSize: Int = 1024,
            onsetHopSize: Int = 512,
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
}
