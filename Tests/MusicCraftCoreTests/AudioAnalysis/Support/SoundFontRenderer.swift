import Foundation
import AVFoundation
import CoreAudio

// Deferred — SoundFont rendering produces synthetic fixtures that don't exercise AudioExtractor's real-guitar tuning.
// Retained for future command-line tool target. Real-audio testing uses GADA and TaylorNylon datasets.

/// Offline SoundFont renderer using AVAudioUnitSampler with proper MIDI scheduling.
/// Captures rendered output via tap on output node.
struct SoundFontRenderer {
    enum Error: LocalizedError {
        case engineInitializationFailed
        case samplerLoadFailed(String)
        case renderingFailed(String)
        case formatMismatch
        case unsupportedConfiguration

        var errorDescription: String? {
            switch self {
            case .engineInitializationFailed:
                return "Failed to initialize audio engine for offline rendering"
            case .samplerLoadFailed(let reason):
                return "Failed to load SoundFont: \(reason)"
            case .renderingFailed(let reason):
                return "Rendering failed: \(reason)"
            case .formatMismatch:
                return "Audio format mismatch"
            case .unsupportedConfiguration:
                return "Unsupported audio configuration"
            }
        }
    }

    /// Render MIDI events offline using a SoundFont (or system DLS) with the specified program.
    static func render(
        events: [MIDIEvent],
        program: UInt8 = 24,  // General MIDI program 24 = Acoustic Guitar (nylon)
        sampleRate: Double = 44100.0
    ) throws -> [Float] {
        // Calculate total duration from events
        let maxTime = events.compactMap { event -> TimeInterval? in
            switch event {
            case .noteOn(_, _, let t), .noteOff(_, let t):
                return t
            case .silence:
                return nil
            }
        }.max() ?? 0.0

        let totalFrames = Int(maxTime * sampleRate) + Int(0.5 * sampleRate)  // +500ms tail

        // Initialize audio engine
        let engine = AVAudioEngine()
        let sampler = AVAudioUnitSampler()
        engine.attach(sampler)

        // Create mixer for output capture
        let mixer = AVAudioMixerNode()
        engine.attach(mixer)

        // Connect sampler to mixer to output
        let mainMixer = engine.mainMixerNode
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)
        guard let format = format else {
            throw Error.formatMismatch
        }

        engine.connect(sampler, to: mixer, format: format)
        engine.connect(mixer, to: mainMixer, format: format)

        // Load SoundFont: try system DLS first, fall back to bundled FluidR3_GM
        let soundFontLoaded = try loadSoundFont(into: sampler, program: program)
        guard soundFontLoaded else {
            throw Error.samplerLoadFailed("Neither system DLS nor FluidR3_GM SoundFont available")
        }

        // Set up output capture
        var capturedFrames: [Float] = []
        let capturedFramesLock = NSLock()

        mainMixer.installTap(onBus: 0, bufferSize: AVAudioFrameCount(4096), format: format) { buffer, _ in
            capturedFramesLock.lock()
            if let floatChannelData = buffer.floatChannelData {
                let count = Int(buffer.frameLength)
                let data = Array(UnsafeBufferPointer(start: floatChannelData[0], count: count))
                capturedFrames.append(contentsOf: data)
            }
            capturedFramesLock.unlock()
        }

        // Start engine and play events
        try engine.start()

        // Play MIDI events with timing
        let queue = DispatchQueue(label: "com.mcc.soundfont.playback")
        let durationSeconds = TimeInterval(totalFrames) / sampleRate

        // Schedule MIDI events
        for event in events {
            let delaySeconds: TimeInterval
            switch event {
            case .noteOn(let note, let velocity, let time):
                delaySeconds = time
                queue.asyncAfter(deadline: .now() + delaySeconds) {
                    sampler.startNote(note, withVelocity: velocity, onChannel: 0)
                }

            case .noteOff(let note, let time):
                delaySeconds = time
                queue.asyncAfter(deadline: .now() + delaySeconds) {
                    sampler.stopNote(note, onChannel: 0)
                }

            case .silence:
                break
            }
        }

        // Wait for playback to complete
        Thread.sleep(forTimeInterval: durationSeconds)

        // Stop engine
        engine.mainMixerNode.removeTap(onBus: 0)
        try engine.stop()

        capturedFramesLock.lock()
        let result = capturedFrames
        capturedFramesLock.unlock()

        return result
    }

    // MARK: - SoundFont Loading

    private static func loadSoundFont(into sampler: AVAudioUnitSampler, program: UInt8) throws -> Bool {
        // Try system DLS first
        let systemDLSPath = "/System/Library/Components/CoreAudio.component/Contents/Resources/gs_instruments.dls"
        if FileManager.default.fileExists(atPath: systemDLSPath) {
            let url = URL(fileURLWithPath: systemDLSPath)
            do {
                try sampler.loadInstrument(at: url)
                return true
            } catch {
                // Fall through to FluidR3_GM
            }
        }

        // Try FluidR3_GM SoundFont (bundled in test resources)
        let testBundle = Bundle(for: SoundFontRendererTest.self)
        if let soundFontURL = testBundle.url(forResource: "FluidR3_GM", withExtension: "sf2") {
            do {
                try sampler.loadInstrument(at: soundFontURL)
                return true
            } catch {
                return false
            }
        }

        return false
    }
}

// Dummy test class to get test bundle
private class SoundFontRendererTest {}
