import XCTest
@testable import MusicCraftCore

/// The Whisper routing rule as pure logic — no model, no audio, no network. Every case pins a
/// clause of `LyricsExtractor.whisperDecodeLanguage` (language-honesty spec, 2026-08-13):
/// a caller-forced non-English `transcriptionLanguage` routes to Whisper regardless of locale
/// (measured on the Te Amo take: forced-es 49/54 words vs forced-en 39/54 vs detect 22/54, with
/// the English bridge riding along word-perfect under forced-es); "en" — the field's default —
/// keeps the original 2026-08-07 English-locale gate; nil (Whisper detection, measured
/// confidently dishonest on sung audio) never routes to Whisper at all.
final class LyricsExtractorRoutingTests: XCTestCase {

    /// The rule never touches the filesystem, so any non-nil URL stands in for a model folder.
    private let modelFolder = URL(fileURLWithPath: "/tmp/openai_whisper-small")

    private func config(language: String?) -> LyricsExtractor.Configuration {
        LyricsExtractor.Configuration(whisperModelFolder: modelFolder,
                                      transcriptionLanguage: language)
    }

    // MARK: - The default configuration (transcriptionLanguage "en")

    func testDefaultConfigRoutesEnglishLocaleToWhisperAsEnglish() {
        // The shipping path, unchanged: English request + model folder → Whisper, forced "en".
        let configuration = LyricsExtractor.Configuration(whisperModelFolder: modelFolder)
        XCTAssertEqual(
            LyricsExtractor.whisperDecodeLanguage(localeIdentifier: "en-US",
                                                  configuration: configuration),
            "en"
        )
    }

    func testDefaultConfigKeepsEnglishGateForNonEnglishLocale() {
        // The original gate's protected caller: a Spanish REQUEST under a default configuration
        // goes to the Apple path in its own locale, never a silent English-forced decode (the
        // measured hallucination: "I'm going to go to the hospital." for "Te amo madre, amo tu
        // medicina").
        let configuration = LyricsExtractor.Configuration(whisperModelFolder: modelFolder)
        XCTAssertNil(
            LyricsExtractor.whisperDecodeLanguage(localeIdentifier: "es-ES",
                                                  configuration: configuration)
        )
    }

    func testEnglishGateMatchesLocalePrefixCaseInsensitively() {
        // The locale side of the gate is a case-insensitive prefix match, verbatim from the
        // 2026-08-07 gate: "EN-us" is an English request; "eN" alone is too.
        let configuration = LyricsExtractor.Configuration(whisperModelFolder: modelFolder)
        XCTAssertEqual(
            LyricsExtractor.whisperDecodeLanguage(localeIdentifier: "EN-us",
                                                  configuration: configuration),
            "en"
        )
        XCTAssertEqual(
            LyricsExtractor.whisperDecodeLanguage(localeIdentifier: "eN",
                                                  configuration: configuration),
            "en"
        )
    }

    func testExplicitEnglishUnderNonEnglishLocaleTakesApplePath() {
        // The documented accepted edge: an explicit "en" is indistinguishable from the default,
        // so it is gated exactly like the default. Uppercase spelling gates the same way.
        XCTAssertNil(
            LyricsExtractor.whisperDecodeLanguage(localeIdentifier: "fr-FR",
                                                  configuration: config(language: "en"))
        )
        XCTAssertNil(
            LyricsExtractor.whisperDecodeLanguage(localeIdentifier: "fr-FR",
                                                  configuration: config(language: "EN"))
        )
    }

    // MARK: - Caller-forced non-English codes (THE 2026-08-13 change)

    func testForcedSpanishRoutesToWhisperRegardlessOfLocale() {
        // The Te Amo fix itself: forced-es must reach Whisper under ANY locale — including the
        // English locale the old gate required and the Spanish locale it used to reject.
        for locale in ["en-US", "es-ES", "es", "fr-FR", "ja-JP"] {
            XCTAssertEqual(
                LyricsExtractor.whisperDecodeLanguage(localeIdentifier: locale,
                                                      configuration: config(language: "es")),
                "es",
                "forced-es must route to Whisper under locale \(locale)"
            )
        }
    }

    func testForcedCodeRoutesForAnyModelSupportedLanguage() {
        // The rule carries the caller's code verbatim — spot-checked across the tokenizer's
        // range, majors to the low-resource tail (the model's own tokenizer_config.json is the
        // membership ground truth; MCC never hardcodes the list).
        for code in ["de", "pt", "ja", "ko", "uk", "haw", "la"] {
            XCTAssertEqual(
                LyricsExtractor.whisperDecodeLanguage(localeIdentifier: "en-US",
                                                      configuration: config(language: code)),
                code,
                "forced-\(code) must route to Whisper"
            )
        }
    }

    func testForcedCodePassesThroughWithoutNormalization() {
        // MCC does not validate or rewrite the code: an unsupported one fails the DECODE and
        // lands on the Apple fallback — the routing rule's job is only to carry it.
        XCTAssertEqual(
            LyricsExtractor.whisperDecodeLanguage(localeIdentifier: "en-US",
                                                  configuration: config(language: "xx")),
            "xx"
        )
    }

    // MARK: - nil: detection stays closed

    func testNilLanguageNeverRoutesToWhisper() {
        // nil documents Whisper detection, RETIRED as a routing option (detect 22/54 on Te Amo,
        // wrong language per slice, junk-glyph runs). No locale reaches Whisper with nil — not
        // even English, which previously coalesced nil to a forced "en".
        for locale in ["en-US", "es-ES", "de-DE"] {
            XCTAssertNil(
                LyricsExtractor.whisperDecodeLanguage(localeIdentifier: locale,
                                                      configuration: config(language: nil)),
                "nil transcriptionLanguage must take the Apple path under locale \(locale)"
            )
        }
    }

    // MARK: - No model folder / no configuration

    func testNoModelFolderNeverRoutesToWhisper() {
        // Whisper cannot run without a model to load, whatever language is forced.
        let configuration = LyricsExtractor.Configuration(transcriptionLanguage: "es")
        XCTAssertNil(
            LyricsExtractor.whisperDecodeLanguage(localeIdentifier: "es-ES",
                                                  configuration: configuration)
        )
    }

    func testNilConfigurationNeverRoutesToWhisper() {
        XCTAssertNil(
            LyricsExtractor.whisperDecodeLanguage(localeIdentifier: "en-US",
                                                  configuration: nil)
        )
    }
}
