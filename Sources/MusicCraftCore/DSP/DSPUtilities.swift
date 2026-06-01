import Accelerate
import Foundation

public struct DSPUtilities {
    /// Create a Hann window for spectral analysis.
    /// Window length must match FFT size for proper scaling.
    public static func hannWindow(length: Int) -> [Float] {
        var window = [Float](repeating: 0, count: length)
        vDSP_hann_window(&window, vDSP_Length(length), Int32(vDSP_HANN_NORM))
        return window
    }

    /// Create a Blackman window for spectral analysis.
    /// Provides ~58 dB sidelobe suppression, superior to Hann for chord detection.
    public static func blackmanWindow(length: Int) -> [Float] {
        var window = [Float](repeating: 0, count: length)
        vDSP_blkman_window(&window, vDSP_Length(length), 0)
        return window
    }

    /// Apply a window to audio samples in-place.
    public static func applyWindow(_ window: [Float], to samples: inout [Float]) {
        let count = min(window.count, samples.count)
        vDSP_vmul(samples, 1, window, 1, &samples, 1, vDSP_Length(count))
    }

    /// Compute log2 of the smallest power of 2 >= length (for FFT setup).
    public static func log2Ceil(_ length: Int) -> UInt {
        guard length > 0 else { return 0 }
        return UInt(ceil(log2(Double(length))))
    }
}
