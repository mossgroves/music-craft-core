import Accelerate
import Foundation

/// Calibrates a noise baseline from genuine silence frames in an audio buffer.
///
/// Scans an audio buffer for windows where RMS energy is below a silence threshold,
/// extracts chroma vectors from those windows, and averages them to produce a
/// NoiseBaseline suitable for subtraction from signal chroma. Includes a contamination
/// safeguard to reject baselines that contain too much energy (indicating the
/// "silence" windows were not actually quiet).
public enum NoiseCalibrator {

    /// Scan a PCM buffer for genuine silence windows and compute a noise baseline chroma vector.
    ///
    /// Algorithm:
    /// - Scans the buffer with a 50% overlapping window at `windowSize` samples.
    /// - For windows where RMS < `silenceThreshold`, extracts chroma using ChromaExtractor.
    /// - Averages chroma vectors from silence windows (up to `minSilenceFrames` frames).
    /// - Returns nil if fewer than `minSilenceFrames` silence windows are found (continuous playback).
    /// - Returns nil if the accumulated baseline's totalEnergy exceeds `contaminationLimit` (safeguard).
    ///
    /// The baseline is intended for subtraction from chord-detection chroma vectors to reduce
    /// noise contamination without removing legitimate signal.
    ///
    /// - Parameters:
    ///   - buffer: Mono Float32 PCM samples.
    ///   - sampleRate: Sample rate in Hz.
    ///   - windowSize: Chroma window size in samples. Default 8192.
    ///   - hopSize: Window hop size (overlap) in samples. Default 4096 (50% overlap).
    ///   - silenceThreshold: RMS threshold for silence detection. Default 0.001 (-60dB).
    ///   - minSilenceFrames: Minimum silence windows required for calibration. Default 10.
    ///   - contaminationLimit: Maximum allowable totalEnergy in baseline. Default 5.0. Returns nil if exceeded.
    /// - Returns: Calibrated baseline, or nil if no genuine silence or baseline is contaminated.
    public static func calibrateBaseline(
        buffer: [Float],
        sampleRate: Double,
        windowSize: Int = 8192,
        hopSize: Int = 4096,
        silenceThreshold: Float = 0.001,
        minSilenceFrames: Int = 10,
        contaminationLimit: Double = 5.0
    ) -> NoiseBaseline? {
        guard buffer.count >= windowSize else { return nil }

        let chromaExtractor = ChromaExtractor(bufferSize: windowSize, sampleRate: sampleRate)
        var accumulatedChroma = [Double](repeating: 0.0, count: 12)
        var silenceFrameCount = 0

        // Scan buffer for silence windows
        var pos = 0
        while pos + windowSize <= buffer.count {
            var rms: Float = 0
            buffer.withUnsafeBufferPointer { ptr in
                vDSP_rmsqv(ptr.baseAddress! + pos, 1, &rms, vDSP_Length(windowSize))
            }

            // Found a genuine silence window
            if rms < silenceThreshold {
                let slice = Array(buffer[pos..<(pos + windowSize)])
                let chroma = slice.withUnsafeBufferPointer { ptr in
                    chromaExtractor.extractChroma(buffer: UnsafeMutablePointer(mutating: ptr.baseAddress!), count: windowSize)
                }

                // Accumulate chroma
                for i in 0..<12 {
                    accumulatedChroma[i] += chroma[i]
                }
                silenceFrameCount += 1

                // Stop once we have enough silence frames
                if silenceFrameCount >= minSilenceFrames {
                    break
                }
            }

            pos += hopSize
        }

        // Check if we found enough silence
        guard silenceFrameCount >= minSilenceFrames else {
            return nil
        }

        // Average the accumulated chroma
        let averagedChroma = accumulatedChroma.map { $0 / Double(silenceFrameCount) }

        // Contamination safeguard
        let totalEnergy = averagedChroma.reduce(0, +)
        guard totalEnergy <= contaminationLimit else {
            return nil
        }

        return NoiseBaseline(chroma: averagedChroma, frameCount: silenceFrameCount)
    }
}
