import Foundation

// Deferred — SoundFont rendering produces synthetic fixtures that don't exercise AudioExtractor's real-guitar tuning.
// Retained for future command-line tool target. Real-audio testing uses GADA and TaylorNylon datasets.

/// A MIDI event for fixture generation.
enum MIDIEvent {
    /// Note on: pitch + velocity + timing.
    case noteOn(midiNote: UInt8, velocity: UInt8, atSeconds: TimeInterval)

    /// Note off: pitch + timing.
    case noteOff(midiNote: UInt8, atSeconds: TimeInterval)

    /// Silence: duration in seconds.
    case silence(seconds: TimeInterval)

    /// Get the event's absolute time in seconds.
    var timeInSeconds: TimeInterval {
        switch self {
        case .noteOn(_, _, let t), .noteOff(_, let t):
            return t
        case .silence:
            return 0  // Silence has no absolute time; only duration
        }
    }
}
