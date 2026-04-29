import Foundation
import MusicCraftCore

/// JAMS (JSON Annotation Metadata Schema) parser for GuitarSet fixtures.
/// Scope: Reads only `chord_harte`, `beat`, and `key_mode` namespaces.
/// No external dependencies; uses only Foundation.JSONDecoder.
struct JAMSParser {
    /// Parse a JAMS file and extract chord, beat, and key annotations.
    static func parse(url: URL) throws -> ParsedGuitarSetData {
        let data = try Data(contentsOf: url)
        let decodedAny = try JSONDecoder().decode([String: JAMSAnyCodable].self, from: data)

        // Convert decoded types to usable format
        var jamsDict: [String: JAMSAnyCodable] = [:]
        for (k, v) in decodedAny {
            jamsDict[k] = v
        }

        // Extract file metadata for duration
        guard let fileMetadata = jamsDict["file_metadata"]?.dictValue else {
            throw JAMSError.missingMetadata
        }
        guard let duration = fileMetadata["duration"]?.doubleValue else {
            throw JAMSError.missingDuration
        }

        // Extract namespaces: we read chord_harte, beat, and key_mode only
        var chordSegments: [GroundTruth.ChordSegment] = []
        var beatTimes: [TimeInterval] = []
        var keyString: String? = nil

        guard let namespaces = jamsDict["annotations"]?.arrayValue else {
            throw JAMSError.missingAnnotations
        }

        for annotationObj in namespaces {
            guard let annotation = annotationObj.dictValue else { continue }

            guard let namespace = annotation["namespace"]?.stringValue else { continue }
            guard let data = annotation["data"]?.arrayValue else { continue }

            switch namespace {
            case "chord", "chord_harte":
                // GuitarSet can have "chord" or "chord_harte" namespace
                // Data format: {"time": ..., "duration": ..., "value": "D#:maj", ...}
                for item in data {
                    guard let itemDict = item.dictValue,
                          let time = itemDict["time"]?.doubleValue else {
                        continue
                    }

                    // Value can be a direct string (GuitarSet format) or nested dict (fallback)
                    let harteString: String?
                    if let valueStr = itemDict["value"]?.stringValue {
                        harteString = valueStr
                    } else if let valueDict = itemDict["value"]?.dictValue,
                              let harteStr = valueDict["chord"]?.stringValue {
                        harteString = harteStr
                    } else {
                        continue
                    }

                    guard let harteString = harteString else { continue }

                    // Skip "N" (no-chord) regions and silence
                    if harteString == "N" { continue }

                    // Translate Harte notation to MCC displayName
                    let mccChord = HarteTranslator.translate(harteString)

                    // GuitarSet format includes duration; use it for endTime
                    let duration = itemDict["duration"]?.doubleValue ?? 0
                    let endTime = duration > 0 ? time + duration : time

                    let segment = GroundTruth.ChordSegment(
                        chord: mccChord,
                        startTime: time,
                        endTime: endTime,
                        confidence: 1.0
                    )
                    chordSegments.append(segment)
                }

            case "beat", "beat_position":
                // GuitarSet may have "beat_position" namespace with complex structure,
                // or simple "beat" namespace. Extract beat times from beat_position.
                for item in data {
                    guard let itemDict = item.dictValue,
                          let beatTime = itemDict["time"]?.doubleValue else {
                        continue
                    }
                    beatTimes.append(beatTime)
                }

            case "tempo":
                // GuitarSet tempo namespace: extract tempo in BPM
                // We store beat times, so we'll skip this for now
                // (tempo is used to derive BPM from inter-beat intervals if beats are sparse)
                break

            case "key_mode":
                // Key mode typically has one value describing the entire file
                for item in data {
                    guard let itemDict = item.dictValue else { continue }

                    // GuitarSet key_mode value is a string like "Eb:major"
                    if let keyValue = itemDict["value"]?.stringValue {
                        keyString = keyValue
                    }
                    // Alternative format: value is a dict with "root" and "mode" keys
                    else if let valueDict = itemDict["value"]?.dictValue {
                        if let root = valueDict["root"]?.stringValue,
                           let mode = valueDict["mode"]?.stringValue {
                            keyString = "\(root):\(mode)"
                        }
                    }
                }

            default:
                // Ignore other namespaces
                break
            }
        }

        // Post-process chord segments: if endTime equals startTime (no duration was set),
        // calculate from next chord's startTime or end of file
        var processedSegments: [GroundTruth.ChordSegment] = []
        for i in 0..<chordSegments.count {
            let segment = chordSegments[i]

            // Only recalculate if endTime wasn't set by duration
            let endTime = segment.endTime > segment.startTime ? segment.endTime :
                         (i + 1 < chordSegments.count ? chordSegments[i + 1].startTime : duration)

            let corrected = GroundTruth.ChordSegment(
                chord: segment.chord,
                startTime: segment.startTime,
                endTime: endTime,
                confidence: segment.confidence
            )
            processedSegments.append(corrected)
        }
        chordSegments = processedSegments

        // Sort beat times
        beatTimes.sort()

        return ParsedGuitarSetData(
            chordSegments: chordSegments,
            beatTimes: beatTimes,
            key: keyString,
            duration: duration
        )
    }
}

/// Result of parsing a JAMS file.
struct ParsedGuitarSetData {
    let chordSegments: [GroundTruth.ChordSegment]
    let beatTimes: [TimeInterval]
    let key: String?  // e.g. "C:major", "A:minor"
    let duration: TimeInterval

    /// Derive tempo in BPM from beat times using median inter-beat interval.
    var derivedTempoBPM: Int? {
        guard beatTimes.count > 1 else { return nil }

        var intervals: [TimeInterval] = []
        for i in 1..<beatTimes.count {
            let ibi = beatTimes[i] - beatTimes[i - 1]
            if ibi > 0 { intervals.append(ibi) }
        }

        guard !intervals.isEmpty else { return nil }

        let sorted = intervals.sorted()
        let medianIBI = sorted[sorted.count / 2]

        // BPM = 60 / (inter-beat interval in seconds)
        let bpm = 60.0 / medianIBI
        return Int(round(bpm))
    }
}

/// Translates Harte notation chord symbols to MCC displayName format.
/// Harte uses format: "Root:Quality" (e.g., "A:min", "C:maj", "G:7")
/// MCC uses: "C", "Am", "G7", "Bbmaj7", etc.
enum HarteTranslator {
    static func translate(_ harteString: String) -> String {
        // Remove leading/trailing whitespace
        let cleaned = harteString.trimmingCharacters(in: .whitespaces)

        // Harte chord always has colon; split on it
        let parts = cleaned.split(separator: ":", maxSplits: 1)
        guard parts.count == 2 else {
            return cleaned  // fallback: return as-is
        }

        let rootStr = String(parts[0]).trimmingCharacters(in: .whitespaces)
        let qualityStr = String(parts[1]).trimmingCharacters(in: .whitespaces)

        // Translate root (in Harte, roots are note names with optional accidentals)
        // Harte uses uppercase note names: C, D, E, F, G, A, B, with # or b for accidentals
        // We keep the root as-is (C, A#, Bb, etc.)

        // Translate quality to MCC format
        let mccQuality = translateQuality(qualityStr)

        return rootStr + mccQuality
    }

    private static func translateQuality(_ harteQuality: String) -> String {
        // Map Harte quality suffixes to MCC displayName suffixes
        switch harteQuality {
        case "maj", "M", "major":
            return ""  // Major is implicit (e.g., "C" not "Cmaj")

        case "min", "m", "minor":
            return "m"  // "Am"

        case "dim":
            return "dim"  // "Fdim"

        case "aug", "+":
            return "aug"  // "Caug"

        case "7":
            return "7"  // "G7"

        case "maj7", "M7":
            return "maj7"  // "Cmaj7"

        case "min7", "m7":
            return "m7"  // "Am7"

        case "dom7", "7":
            return "7"  // "G7" (dominant 7)

        case "hdim7", "ø7", "min7b5", "m7b5":
            return "m7b5"  // "Am7b5" (half-diminished)

        case "sus2":
            return "sus2"  // "Asus2"

        case "sus4":
            return "sus4"  // "Asus4"

        case "add9":
            return "add9"  // "Cadd9"

        case "9", "7/9", "79":
            return "9"  // "C9"

        case "11", "7/11", "711":
            return "11"  // "C11"

        case "13", "7/13", "713":
            return "13"  // "C13"

        default:
            // For inversions (e.g., "maj/3" or "min/b7"), extract base quality
            // Harte inversion notation is "quality/interval", but we reduce to root position
            if harteQuality.contains("/") {
                let baseParts = harteQuality.split(separator: "/", maxSplits: 1)
                return translateQuality(String(baseParts[0]))
            }

            // Unknown quality: return as fallback
            return harteQuality
        }
    }
}

/// JAMS parsing errors.
enum JAMSError: Error {
    case missingMetadata
    case missingDuration
    case missingAnnotations
}

/// Helper for polymorphic JSON decoding.
/// Allows flexible value types (string, number, dict, array).
enum JAMSAnyCodable: Codable {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)
    case array([JAMSAnyCodable])
    case dict([String: JAMSAnyCodable])
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()

        if container.decodeNil() {
            self = .null
        } else if let str = try? container.decode(String.self) {
            self = .string(str)
        } else if let int = try? container.decode(Int.self) {
            self = .int(int)
        } else if let dbl = try? container.decode(Double.self) {
            self = .double(dbl)
        } else if let bool = try? container.decode(Bool.self) {
            self = .bool(bool)
        } else if let arr = try? container.decode([JAMSAnyCodable].self) {
            self = .array(arr)
        } else if let dict = try? container.decode([String: JAMSAnyCodable].self) {
            self = .dict(dict)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Cannot decode AnyCodable"
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let str):
            try container.encode(str)
        case .int(let int):
            try container.encode(int)
        case .double(let dbl):
            try container.encode(dbl)
        case .bool(let bool):
            try container.encode(bool)
        case .array(let arr):
            try container.encode(arr)
        case .dict(let dict):
            try container.encode(dict)
        case .null:
            try container.encodeNil()
        }
    }

    // Convenience accessors
    var stringValue: String? {
        if case .string(let str) = self { return str }
        return nil
    }

    var intValue: Int? {
        if case .int(let int) = self { return int }
        if case .double(let dbl) = self { return Int(dbl) }
        return nil
    }

    var doubleValue: Double? {
        if case .double(let dbl) = self { return dbl }
        if case .int(let int) = self { return Double(int) }
        return nil
    }

    var boolValue: Bool? {
        if case .bool(let bool) = self { return bool }
        return nil
    }

    var arrayValue: [JAMSAnyCodable]? {
        if case .array(let arr) = self { return arr }
        return nil
    }

    var dictValue: [String: JAMSAnyCodable]? {
        if case .dict(let dict) = self { return dict }
        return nil
    }
}
