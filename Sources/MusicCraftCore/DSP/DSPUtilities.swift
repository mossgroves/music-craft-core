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

public class ChromaExtractor {
    private let fftSetup: OpaquePointer
    private let log2n: UInt
    private let halfN: Int
    private let sampleRate: Double
    private var windowedBuffer: [Float]
    private var realPart: [Float]
    private var imagPart: [Float]
    private var magnitudes: [Float]
    private let window: [Float]

    public var noiseBaseline: [Double]?
    private var calibrationFrames: [[Double]] = []
    private let calibrationFrameCount = 10

    public init(bufferSize: Int = 2048, sampleRate: Double = 44100) {
        self.sampleRate = sampleRate
        self.log2n = DSPUtilities.log2Ceil(bufferSize)
        self.halfN = bufferSize / 2

        guard let setup = vDSP_create_fftsetup(log2n, Int32(kFFTRadix2)) else {
            fatalError("Failed to create FFT setup")
        }
        self.fftSetup = setup

        self.windowedBuffer = [Float](repeating: 0, count: bufferSize)
        self.realPart = [Float](repeating: 0, count: halfN)
        self.imagPart = [Float](repeating: 0, count: halfN)
        self.magnitudes = [Float](repeating: 0, count: halfN)
        self.window = DSPUtilities.blackmanWindow(length: bufferSize)
    }

    deinit {
        vDSP_destroy_fftsetup(fftSetup)
    }

    /// Extract chroma vector from audio buffer.
    /// Performs FFT, maps to pitch classes with 1/octave weighting, subtracts noise baseline.
    public func extractChroma(buffer: UnsafePointer<Float>, count: Int) -> [Double] {
        let effectiveCount = min(count, windowedBuffer.count)

        // Apply window
        for i in 0..<effectiveCount {
            windowedBuffer[i] = buffer[i] * window[i]
        }
        if effectiveCount < windowedBuffer.count {
            for i in effectiveCount..<windowedBuffer.count {
                windowedBuffer[i] = 0
            }
        }

        // FFT: vDSP_ctoz interleaves real/imag into split form
        var chroma = [Double](repeating: 0, count: 12)

        realPart.withUnsafeMutableBufferPointer { realBuffer in
            imagPart.withUnsafeMutableBufferPointer { imagBuffer in
                var splitComplex = DSPSplitComplex(
                    realp: realBuffer.baseAddress!,
                    imagp: imagBuffer.baseAddress!
                )

                vDSP_ctoz(
                    unsafeBitCast(windowedBuffer, to: UnsafePointer<DSPComplex>.self),
                    2,
                    &splitComplex,
                    1,
                    vDSP_Length(halfN)
                )

                // Perform FFT
                vDSP_fft_zrip(fftSetup, &splitComplex, 1, log2n, Int32(kFFTDirection_Forward))

                // Compute magnitudes: sqrt(real^2 + imag^2)
                vDSP_zvmags(&splitComplex, 1, &magnitudes, 1, vDSP_Length(halfN))

                // Map FFT bins to chroma with 1/octave weighting
                let freqPerBin = sampleRate / Double(windowedBuffer.count)

                for bin in 0..<halfN {
                    let freq = Double(bin) * freqPerBin
                    guard freq >= 65 && freq <= 2000 else { continue }

                    let midiNote = 12.0 * log2(freq / 440.0) + 69.0
                    let pitchClass = Int(round(midiNote.truncatingRemainder(dividingBy: 12))) % 12

                    // 1/octave weighting: lower frequencies (lower octaves) contribute more
                    let octave = (midiNote - 12) / 12.0
                    let octaveWeight = octave > 0 ? 1.0 / octave : 1.0

                    let magnitude = sqrt(Double(magnitudes[bin]))
                    chroma[pitchClass] += magnitude * octaveWeight
                }
            }
        }

        // Subtract noise baseline if calibrated
        if let baseline = noiseBaseline {
            for i in 0..<chroma.count {
                if chroma[i] > 0.10 {
                    chroma[i] = max(chroma[i] * 0.10, chroma[i] - baseline[i])
                }
            }
        }

        // Normalize to [0, 1.0]
        let maxChroma = chroma.max() ?? 1.0
        if maxChroma > 0 {
            chroma = chroma.map { $0 / maxChroma }
        }

        return chroma
    }

    /// Calibrate noise baseline from a frame.
    /// Accumulates frames until calibrationFrameCount is reached, then averages.
    public func calibrateNoiseBaseline(frame: [Double]) {
        calibrationFrames.append(frame)
        if calibrationFrames.count >= calibrationFrameCount {
            var baseline = [Double](repeating: 0, count: 12)
            for frame in calibrationFrames {
                for i in 0..<12 {
                    baseline[i] += frame[i]
                }
            }
            for i in 0..<12 {
                baseline[i] /= Double(calibrationFrameCount)
            }
            self.noiseBaseline = baseline
            calibrationFrames.removeAll()
        }
    }
}
