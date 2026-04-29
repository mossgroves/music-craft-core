import XCTest
import Foundation
import CryptoKit

/// GuitarSet downloader test suite.
/// Downloads 20 GuitarSet fixtures (audio + JAMS) from Zenodo.
/// Gated by environment variable: MCC_DOWNLOAD_GUITARSET=1
///
/// Run with:
///   MCC_DOWNLOAD_GUITARSET=1 swift test --filter GuitarSetDownloaderTests
///
/// This is a one-time setup; fixtures are checked into git after first run.
final class GuitarSetDownloaderTests: XCTestCase {
    let isDownloadEnabled = ProcessInfo.processInfo.environment["MCC_DOWNLOAD_GUITARSET"] == "1"

    // MARK: - Fixture Manifest

    /// Hardcoded manifest of 20 fixtures to download.
    /// Format: (genre, player, filename, expected_sha256)
    struct FixtureManifest {
        static let entries: [(genre: String, id: String)] = [
            ("BN", "00_BN1-129-Eb_comp"),
            ("BN", "01_BN1-129-Eb_comp"),
            ("BN", "02_BN1-129-Eb_comp"),
            ("BN", "03_BN1-129-Eb_comp"),
            ("BN", "04_BN1-129-Eb_comp"),
            ("Funk", "00_Funk1-119-A_comp"),
            ("Funk", "01_Funk1-119-A_comp"),
            ("Funk", "02_Funk1-119-A_comp"),
            ("Funk", "03_Funk1-119-A_comp"),
            ("Funk", "04_Funk1-119-A_comp"),
            ("Rock", "00_Rock1-130-A_comp"),
            ("Rock", "01_Rock1-130-A_comp"),
            ("Rock", "02_Rock1-130-A_comp"),
            ("Rock", "03_Rock1-130-A_comp"),
            ("Rock", "04_Rock1-130-A_comp"),
            ("SS", "00_SS1-68-E_comp"),
            ("SS", "01_SS1-68-E_comp"),
            ("SS", "02_SS1-68-E_comp"),
            ("SS", "03_SS1-68-E_comp"),
            ("SS", "04_SS1-68-E_comp"),
        ]
    }

    // MARK: - Download Test

    func testDownloadGuitarSetFixtures() throws {
        guard isDownloadEnabled else {
            throw XCTSkip("Download disabled. Run with MCC_DOWNLOAD_GUITARSET=1 to enable.")
        }

        let fixtureDir = try getFixtureDirectory()
        let annotationZipURL = try downloadFile(
            name: "annotation.zip",
            recordId: "3371780",
            from: "zenodo",
            directory: fixtureDir
        )
        let audioZipURL = try downloadFile(
            name: "audio_hex-pickup_debleeded.zip",
            recordId: "3371780",
            from: "zenodo",
            directory: fixtureDir
        )

        // Extract 20 target files from zips
        var extractedFiles: [(String, URL)] = []
        for entry in FixtureManifest.entries {
            let id = entry.id

            // Extract WAV
            let wavEntry = "audio/audio_hex-pickup_debleeded/\(id).wav"
            let wavURL = fixtureDir.appendingPathComponent("\(id).wav")
            try extractFromZip(audioZipURL, entry: wavEntry, to: wavURL, overwrite: false)
            extractedFiles.append(("\(id).wav", wavURL))

            // Extract JAMS
            let jamsEntry = "annotation/annotation_data/\(id).jams"
            let jamsURL = fixtureDir.appendingPathComponent("\(id).jams")
            try extractFromZip(annotationZipURL, entry: jamsEntry, to: jamsURL, overwrite: false)
            extractedFiles.append(("\(id).jams", jamsURL))

            print("✓ Extracted \(id)")
        }

        // Write MANIFEST.txt
        try writeManifest(
            to: fixtureDir,
            files: extractedFiles,
            zenodoRecordId: "3371780"
        )

        print("\n✓ Downloaded and extracted 20 GuitarSet fixtures to \(fixtureDir.path)")
        print("✓ MANIFEST.txt created with file listing and SHA256 hashes")
    }

    // MARK: - Helper Methods

    private func getFixtureDirectory() throws -> URL {
        let fm = FileManager.default
        let baseDir = URL(fileURLWithPath: "/Users/chris/Documents/Code/mossgroves-music-craft-core/Tests/MusicCraftCoreTests/AudioAnalysis/Fixtures/real-audio/guitarset")

        if !fm.fileExists(atPath: baseDir.path) {
            try fm.createDirectory(at: baseDir, withIntermediateDirectories: true)
        }

        return baseDir
    }

    /// Download a file from Zenodo given a record ID and filename.
    /// Returns URL to the downloaded file.
    private func downloadFile(
        name: String,
        recordId: String,
        from: String,
        directory: URL
    ) throws -> URL {
        let destinationURL = directory.appendingPathComponent(name)

        // Check if file already exists
        if FileManager.default.fileExists(atPath: destinationURL.path) {
            print("ℹ File already exists: \(name)")
            return destinationURL
        }

        print("⏳ Fetching file list from Zenodo record \(recordId)...")

        // Query Zenodo API for file URLs
        let apiURL = URL(string: "https://zenodo.org/api/records/\(recordId)")!
        let data = try Data(contentsOf: apiURL)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]

        guard let files = json["files"] as? [[String: Any]] else {
            throw DownloadError.missingFilesInAPI
        }

        // Find the file by name
        var downloadURL: URL? = nil
        for file in files {
            if let filename = file["filename"] as? String, filename == name,
               let urlStr = file["links"] as? [String: Any],
               let selfLink = urlStr["self"] as? String {
                downloadURL = URL(string: selfLink)
                break
            }
        }

        guard let downloadURL = downloadURL else {
            throw DownloadError.fileNotFoundInRecord(name)
        }

        print("⏳ Downloading \(name) (~600 MB)...")

        // Download synchronously
        let fileData = try Data(contentsOf: downloadURL)

        // Write to disk
        try fileData.write(to: destinationURL)

        print("✓ Downloaded: \(name)")

        return destinationURL
    }

    /// Extract a single entry from a zip file using Process(/usr/bin/unzip).
    /// Non-interactive, uses hardcoded arguments.
    private func extractFromZip(
        _ zipURL: URL,
        entry: String,
        to destination: URL,
        overwrite: Bool = false
    ) throws {
        let fm = FileManager.default

        // Skip if destination exists and overwrite=false
        if !overwrite && fm.fileExists(atPath: destination.path) {
            return
        }

        // Use Process to call /usr/bin/unzip
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = ["-p", zipURL.path, entry]

        let pipe = Pipe()
        process.standardOutput = pipe

        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            throw DownloadError.unzipFailed(entry)
        }

        // Read output from pipe and write to destination
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        try data.write(to: destination)
    }

    /// Write MANIFEST.txt with file listing, hashes, and attribution.
    private func writeManifest(
        to directory: URL,
        files: [(String, URL)],
        zenodoRecordId: String
    ) throws {
        var manifest = """
        # GuitarSet Fixtures Manifest

        **Source:** Zenodo record \(zenodoRecordId)
        **License:** CC-BY 4.0
        **URL:** https://zenodo.org/records/\(zenodoRecordId)

        ## Attribution

        GuitarSet: A Dataset for Guitar Chord and Key Identification
        Travers, M., Pardo, B., & Humphrey, E. J. (2017)
        Citation: Characterizing the diversity of audio representations.
        Machine Learning for Music Discovery Workshop.

        Audio courtesy of the New York University Machine Learning for Acoustics Lab (NYU MARL)
        and Queen Mary University of London Centre for Digital Music.

        ## Files

        """

        for (filename, url) in files.sorted(by: { $0.0 < $1.0 }) {
            let data = try Data(contentsOf: url)
            let hash = SHA256.hash(data: data)
            let hashStr = hash.withUnsafeBytes { ptr in
                ptr.map { String(format: "%02x", $0) }.joined()
            }

            manifest += "- \(filename) (SHA256: \(hashStr))\n"
        }

        let manifestURL = directory.appendingPathComponent("MANIFEST.txt")
        try manifest.write(to: manifestURL, atomically: true, encoding: .utf8)
    }
}

enum DownloadError: Error {
    case missingFilesInAPI
    case fileNotFoundInRecord(String)
    case unzipFailed(String)
}
