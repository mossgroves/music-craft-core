import Foundation

struct SyntheticGenerator {
    /// Generate a pure sine wave at a given frequency.
    static func generateSineWave(
        frequency: Double,
        duration: TimeInterval,
        sampleRate: Double,
        amplitude: Float = 0.5
    ) -> [Float] {
        let sampleCount = Int(duration * sampleRate)
        var samples: [Float] = []
        for i in 0..<sampleCount {
            let t = Double(i) / sampleRate
            let sample = Float(sin(2.0 * .pi * frequency * t)) * amplitude
            samples.append(sample)
        }
        return samples
    }

    /// Generate white noise burst.
    static func generateWhiteNoiseBurst(
        duration: TimeInterval,
        sampleRate: Double,
        amplitude: Float = 0.6
    ) -> [Float] {
        let sampleCount = Int(duration * sampleRate)
        var samples: [Float] = []
        for _ in 0..<sampleCount {
            let sample = Float.random(in: -amplitude...amplitude)
            samples.append(sample)
        }
        return samples
    }

    /// Generate a percussive attack: sine wave at 440 Hz with exponential rise (very fast attack < 3ms).
    static func generateSharpAttack(
        duration: TimeInterval,
        sampleRate: Double,
        amplitude: Float = 0.7
    ) -> [Float] {
        let sampleCount = Int(duration * sampleRate)
        var samples: [Float] = []
        let attackSamples = Int(0.003 * sampleRate)  // 3ms exponential attack

        for i in 0..<sampleCount {
            let t = Double(i) / sampleRate
            let sample = Float(sin(2.0 * .pi * 440.0 * t))

            // Exponential rise for attack, then hold
            var envValue: Float = 1.0
            if i < attackSamples {
                envValue = Float(pow(Double(i) / Double(attackSamples), 2.0))
            }

            samples.append(sample * amplitude * envValue)
        }
        return samples
    }

    /// Generate a chord (sum of sine waves at multiple frequencies) with sharp attack and release envelopes.
    static func generateChordBuffer(
        frequencies: [Double],
        duration: TimeInterval,
        sampleRate: Double,
        amplitude: Float = 0.3,
        attackDuration: TimeInterval = 0.003
    ) -> [Float] {
        let sampleCount = Int(duration * sampleRate)
        var samples = [Float](repeating: 0.0, count: sampleCount)
        let attackSamples = Int(attackDuration * sampleRate)

        // Generate tones
        for frequency in frequencies {
            let wave = generateSineWave(frequency: frequency, duration: duration, sampleRate: sampleRate, amplitude: amplitude)
            for i in 0..<min(sampleCount, wave.count) {
                samples[i] += wave[i]
            }
        }

        // Apply sharp exponential attack envelope at start, then sustain, then release
        let releaseFrames = Int(0.05 * sampleRate) // 50ms release
        for i in 0..<sampleCount {
            var envValue: Float = 1.0

            if i < attackSamples {
                // Exponential rise (very fast attack to trigger onset detection)
                envValue = Float(pow(Double(i) / Double(attackSamples), 2.0))
            } else if i > sampleCount - releaseFrames {
                // Gentle release at end
                let releasePos = sampleCount - i
                envValue = Float(releasePos) / Float(releaseFrames)
            }

            samples[i] *= envValue
        }

        return samples
    }

    /// Generate silence (zero-valued samples).
    static func generateSilence(
        duration: TimeInterval,
        sampleRate: Double
    ) -> [Float] {
        let sampleCount = Int(duration * sampleRate)
        return [Float](repeating: 0.0, count: sampleCount)
    }

    /// Generate a metronome click at a given BPM.
    static func generateMetronomeClick(
        bpm: Int,
        durationSeconds: TimeInterval,
        sampleRate: Double
    ) -> [Float] {
        let beatsPerSecond = Double(bpm) / 60.0
        let beatDuration = 1.0 / beatsPerSecond
        let clickDuration = 0.05  // 50ms click per beat
        let totalSamples = Int(durationSeconds * sampleRate)
        var samples = [Float](repeating: 0.0, count: totalSamples)

        let clickSamples = Int(clickDuration * sampleRate)

        var currentBeatTime = 0.0
        while currentBeatTime < durationSeconds {
            let startSample = Int(currentBeatTime * sampleRate)
            let endSample = min(startSample + clickSamples, totalSamples)

            // Generate a short click (high-frequency sine burst)
            let clickFrequency = 1000.0  // 1 kHz click
            for i in startSample..<endSample {
                let relativeI = i - startSample
                let t = Double(relativeI) / sampleRate
                let sample = Float(sin(2.0 * .pi * clickFrequency * t)) * 0.7
                samples[i] = sample
            }

            currentBeatTime += beatDuration
        }

        return samples
    }
}
