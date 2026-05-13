import Accelerate
import Foundation

/// Spectral-flux onset detection (Dixon 2006 half-wave-rectified formulation).
///
/// Replaces the previous RMS-energy-based onset signal used in BeatTracker.detectBeats,
/// which produced 0% tempo accuracy with systematic 1/3-tempo error on real guitar audio:
/// RMS energy responds to every intra-strum articulation, so autocorrelation locked onto a
/// sub-beat period. Spectral flux counts only *energy increases per bin*, isolating onset
/// events (multiple bins gaining energy simultaneously) from sustains and decays.
///
/// Internal-only; consumed by BeatTracker.detectBeats and TempoEstimator's buffer path.
enum SpectralFluxOnsetDetector {
    /// Detect onset times in seconds from a mono Float32 PCM buffer.
    ///
    /// - Parameters:
    ///   - buffer: Mono PCM samples (Float32).
    ///   - sampleRate: Sample rate in Hz.
    ///   - windowSize: STFT window size. Default 1024.
    ///   - hopSize: STFT hop size. Default 512 (50% overlap).
    ///   - thresholdDelta: Bias added to the local median to form the peak threshold. Default 0.07.
    /// - Returns: Onset times in seconds, sorted ascending. Empty if no onsets detected.
    static func detectOnsets(
        buffer: [Float],
        sampleRate: Double,
        windowSize: Int = 1024,
        hopSize: Int = 512,
        thresholdDelta: Float = 0.07
    ) -> [TimeInterval] {
        guard buffer.count >= windowSize, hopSize > 0 else { return [] }

        let log2n = vDSP_Length(log2(Double(windowSize)).rounded(.toNearestOrEven))
        guard 1 << log2n == windowSize else { return [] }
        guard let fftSetup = vDSP_create_fftsetup(log2n, Int32(kFFTRadix2)) else { return [] }
        defer { vDSP_destroy_fftsetup(fftSetup) }

        let halfN = windowSize / 2
        let window = DSPUtilities.hannWindow(length: windowSize)

        var windowed = [Float](repeating: 0, count: windowSize)
        var realPart = [Float](repeating: 0, count: halfN)
        var imagPart = [Float](repeating: 0, count: halfN)
        var magnitudes = [Float](repeating: 0, count: halfN)
        var prevMagnitudes = [Float](repeating: 0, count: halfN)
        var diffBuf = [Float](repeating: 0, count: halfN)

        var spectralFlux: [Float] = []
        var frameStart = 0

        while frameStart + windowSize <= buffer.count {
            // Window the frame.
            for i in 0..<windowSize {
                windowed[i] = buffer[frameStart + i] * window[i]
            }

            realPart.withUnsafeMutableBufferPointer { realPtr in
                imagPart.withUnsafeMutableBufferPointer { imagPtr in
                    var splitComplex = DSPSplitComplex(
                        realp: realPtr.baseAddress!,
                        imagp: imagPtr.baseAddress!
                    )

                    windowed.withUnsafeBufferPointer { windowedPtr in
                        windowedPtr.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: halfN) { complexPtr in
                            vDSP_ctoz(complexPtr, 2, &splitComplex, 1, vDSP_Length(halfN))
                        }
                    }

                    vDSP_fft_zrip(fftSetup, &splitComplex, 1, log2n, Int32(kFFTDirection_Forward))
                    vDSP_zvmags(&splitComplex, 1, &magnitudes, 1, vDSP_Length(halfN))
                }
            }

            // Half-wave rectified spectral flux: sum of positive magnitude differences per bin.
            // mag[m][k] - mag[m-1][k], clip negatives to zero, then sum.
            vDSP_vsub(prevMagnitudes, 1, magnitudes, 1, &diffBuf, 1, vDSP_Length(halfN))
            var zero: Float = 0
            vDSP_vthr(diffBuf, 1, &zero, &diffBuf, 1, vDSP_Length(halfN))
            var sum: Float = 0
            vDSP_sve(diffBuf, 1, &sum, vDSP_Length(halfN))

            spectralFlux.append(spectralFlux.isEmpty ? 0 : sum)

            // Swap magnitude buffers for next frame.
            swap(&magnitudes, &prevMagnitudes)

            frameStart += hopSize
        }

        guard spectralFlux.count >= 3 else { return [] }

        // Normalize to [0, 1].
        var maxFlux: Float = 0
        vDSP_maxv(spectralFlux, 1, &maxFlux, vDSP_Length(spectralFlux.count))
        guard maxFlux > 0 else { return [] }
        var normalizedFlux = [Float](repeating: 0, count: spectralFlux.count)
        var scale = 1.0 / maxFlux
        vDSP_vsmul(spectralFlux, 1, &scale, &normalizedFlux, 1, vDSP_Length(spectralFlux.count))

        // Adaptive threshold: local median over ±100 ms window plus thresholdDelta.
        let framesPerSecond = sampleRate / Double(hopSize)
        let medianHalfWidth = max(1, Int((0.1 * framesPerSecond).rounded()))
        var thresholds = [Float](repeating: 0, count: normalizedFlux.count)
        for m in 0..<normalizedFlux.count {
            let lo = max(0, m - medianHalfWidth)
            let hi = min(normalizedFlux.count - 1, m + medianHalfWidth)
            let window = Array(normalizedFlux[lo...hi]).sorted()
            let median = window[window.count / 2]
            thresholds[m] = median + thresholdDelta
        }

        // Minimum onset gap: 50 ms.
        let minGapFrames = max(1, Int((0.05 * framesPerSecond).rounded()))

        var onsetFrames: [Int] = []
        var m = 1
        while m < normalizedFlux.count - 1 {
            let value = normalizedFlux[m]
            guard value > thresholds[m],
                  value > normalizedFlux[m - 1],
                  value > normalizedFlux[m + 1] else {
                m += 1
                continue
            }

            // Local-maximum check within ±minGapFrames.
            let lo = max(0, m - minGapFrames)
            let hi = min(normalizedFlux.count - 1, m + minGapFrames)
            var isLocalMax = true
            for k in lo...hi where k != m {
                if normalizedFlux[k] > value {
                    isLocalMax = false
                    break
                }
            }

            if isLocalMax {
                onsetFrames.append(m)
                m += minGapFrames
            } else {
                m += 1
            }
        }

        return onsetFrames.map { TimeInterval($0) * TimeInterval(hopSize) / sampleRate }
    }
}
