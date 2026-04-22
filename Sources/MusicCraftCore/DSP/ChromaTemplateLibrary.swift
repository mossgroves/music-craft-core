import Foundation

/// A library of chord chroma templates that can be queried by distance against a live chroma vector.
///
/// MusicCraftCore ships `CanonicalChromaLibrary` as a default implementation using theoretical
/// chroma templates (120 templates: 12 roots × 10 qualities). Consumer apps with recording-derived
/// training data can provide their own conforming type to override — for example, Cantus provides
/// a library averaged over hundreds of real nylon-string guitar recordings to improve detection
/// accuracy on its specific audio pipeline.
public protocol ChromaTemplateLibrary {
    /// Euclidean distance between a live 12-element chroma vector and the template for a named chord.
    /// Returns `.infinity` if `chordName` is not present in this library.
    func distance(_ chroma: [Double], to chordName: String) -> Double

    /// All chord names for which this library has templates. Used for iteration and coverage queries.
    var availableChordNames: [String] { get }
}
