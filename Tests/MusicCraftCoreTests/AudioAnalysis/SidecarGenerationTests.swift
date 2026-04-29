import XCTest
import Foundation

/// Test for generating JSON ground-truth sidecars alongside real-audio fixtures.
/// Gated behind MCC_GENERATE_SIDECARS=1 environment variable. Run with:
/// MCC_GENERATE_SIDECARS=1 swift test --filter SidecarGenerationTests
final class SidecarGenerationTests: XCTestCase {

    func testGenerateSidecars() throws {
        guard ProcessInfo.processInfo.environment["MCC_GENERATE_SIDECARS"] == "1" else {
            throw XCTSkip("Sidecar generation disabled. Set MCC_GENERATE_SIDECARS=1 to enable.")
        }

        let testBundleURL = Bundle(for: type(of: self)).bundleURL
        let realAudioDir = testBundleURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("AudioAnalysis")
            .appendingPathComponent("Fixtures")
            .appendingPathComponent("real-audio")

        print("Generating sidecars in: \(realAudioDir.path)")

        var gadaCount = 0
        var taylorCount = 0

        // GADA sidecars
        let gadaDir = realAudioDir.appendingPathComponent("gada")
        if FileManager.default.fileExists(atPath: gadaDir.path) {
            gadaCount = try generateGADASidecars(in: gadaDir)
            print("Generated \(gadaCount) GADA sidecars")
        }

        // TaylorNylon sidecars
        let taylorDir = realAudioDir.appendingPathComponent("taylor-nylon")
        if FileManager.default.fileExists(atPath: taylorDir.path) {
            taylorCount = try generateTaylorNylonSidecars(in: taylorDir)
            print("Generated \(taylorCount) TaylorNylon sidecars")
        }

        let totalCount = gadaCount + taylorCount
        print("Total sidecars generated: \(totalCount)")
        XCTAssertGreaterThan(totalCount, 0, "Should generate at least one sidecar")
    }

    // MARK: - GADA Sidecar Generation

    private func generateGADASidecars(in directory: URL) throws -> Int {
        let fileManager = FileManager.default
        guard let contents = try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else {
            return 0
        }

        let wavFiles = contents.filter { $0.pathExtension == "wav" }
        var count = 0

        for wavFile in wavFiles {
            let chordLabel = parseGADAFilename(wavFile.lastPathComponent)
            if let chord = chordLabel {
                let sidecar = GroundTruthCodable(
                    type: .singleChord,
                    data: ["chord": AnyCodable(chord), "confidence": AnyCodable(1.0)]
                )

                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                let jsonData = try encoder.encode(sidecar)

                let jsonURL = wavFile.deletingPathExtension().appendingPathExtension("json")
                try jsonData.write(to: jsonURL)
                count += 1
            }
        }

        return count
    }

    private func parseGADAFilename(_ filename: String) -> String? {
        // Format: ArgSG_Am_open_022_ID4_1.wav
        // parts[0]=ArgSG, parts[1]=Am, parts[2]=open, ...
        // Remove .wav extension first
        let baseName = (filename as NSString).deletingPathExtension
        let parts = baseName.components(separatedBy: "_")
        guard parts.count >= 2 else { return nil }
        return parts[1]  // Chord label is second component
    }

    // MARK: - TaylorNylon Sidecar Generation

    private func generateTaylorNylonSidecars(in directory: URL) throws -> Int {
        let fileManager = FileManager.default
        guard let contents = try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else {
            return 0
        }

        let chordFolders = contents.filter { url in
            var isDir: ObjCBool = false
            fileManager.fileExists(atPath: url.path, isDirectory: &isDir)
            return isDir.boolValue
        }

        var count = 0

        for folder in chordFolders {
            let chordLabel = folder.lastPathComponent
            guard let wavFiles = try? fileManager.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) else {
                continue
            }

            for wavFile in wavFiles where wavFile.pathExtension == "wav" {
                let sidecar = GroundTruthCodable(
                    type: .singleChord,
                    data: ["chord": AnyCodable(chordLabel), "confidence": AnyCodable(1.0)]
                )

                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                let jsonData = try encoder.encode(sidecar)

                let jsonURL = wavFile.deletingPathExtension().appendingPathExtension("json")
                try jsonData.write(to: jsonURL)
                count += 1
            }
        }

        return count
    }
}
