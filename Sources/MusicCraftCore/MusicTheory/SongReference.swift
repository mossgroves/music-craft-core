import Foundation

/// A reference to a song that exemplifies a chord progression or pattern.
public struct SongReference: Equatable, Hashable, Sendable {
    /// Title of the song.
    public let songTitle: String
    /// Artist or composer.
    public let artist: String
    /// Additional detail (e.g., year, album).
    public let detail: String

    /// Initializes a SongReference.
    public init(songTitle: String, artist: String, detail: String) {
        self.songTitle = songTitle
        self.artist = artist
        self.detail = detail
    }
}
