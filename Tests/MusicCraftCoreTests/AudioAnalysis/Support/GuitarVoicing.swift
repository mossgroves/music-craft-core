import Foundation

// Deferred — SoundFont rendering produces synthetic fixtures that don't exercise AudioExtractor's real-guitar tuning.
// Retained for future command-line tool target. Real-audio testing uses GADA and TaylorNylon datasets.

/// Standard guitar voicings as MIDI note arrays (6 strings, low E to high E).
enum GuitarVoicing {
    // Major triads (open voicings)
    case cMajor      // 48, 52, 55, 60, 64, 72
    case dMajor      // 50, 57, 62, 66, 74
    case eMajor      // 40, 47, 52, 56, 59, 64
    case gMajor      // 43, 47, 50, 55, 59, 67
    case aMajor      // 45, 52, 57, 61, 64, 69

    // Minor triads (open voicings)
    case cMinor      // 48, 51, 55, 60, 63, 72
    case dMinor      // 50, 57, 62, 65, 74
    case eMinor      // 40, 47, 52, 55, 59, 64
    case gMinor      // 43, 46, 50, 55, 58, 67
    case aMinor      // 45, 52, 57, 60, 64, 69

    // Barre chords (moveable patterns)
    case fMajor      // 41, 48, 53, 57, 60, 65 (barre)
    case bMinor      // 47, 54, 59, 62, 66, 71 (barre)

    // Seventh chords
    case cMaj7       // 48, 52, 55, 59, 64, 72
    case cMin7       // 48, 51, 55, 58, 63, 72
    case c7          // 48, 52, 55, 58, 64, 72

    /// Get the MIDI notes for this voicing.
    var midiNotes: [UInt8] {
        switch self {
        case .cMajor:  return [48, 52, 55, 60, 64, 72]
        case .dMajor:  return [50, 57, 62, 66, 74, 50]  // Octave variation
        case .eMajor:  return [40, 47, 52, 56, 59, 64]
        case .gMajor:  return [43, 47, 50, 55, 59, 67]
        case .aMajor:  return [45, 52, 57, 61, 64, 69]

        case .cMinor:  return [48, 51, 55, 60, 63, 72]
        case .dMinor:  return [50, 57, 62, 65, 74, 50]
        case .eMinor:  return [40, 47, 52, 55, 59, 64]
        case .gMinor:  return [43, 46, 50, 55, 58, 67]
        case .aMinor:  return [45, 52, 57, 60, 64, 69]

        case .fMajor:  return [41, 48, 53, 57, 60, 65]
        case .bMinor:  return [47, 54, 59, 62, 66, 71]

        case .cMaj7:   return [48, 52, 55, 59, 64, 72]
        case .cMin7:   return [48, 51, 55, 58, 63, 72]
        case .c7:      return [48, 52, 55, 58, 64, 72]
        }
    }
}
