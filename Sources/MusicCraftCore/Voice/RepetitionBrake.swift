import CoreML
import Foundation
import WhisperKit

/// THE DECODE-TIME REPETITION BRAKE (0.1.17, Chris's word 2026-09-02; measured in Sanctuary's
/// `docs/audits/repetition-levers-2026-09-01.md`).
///
/// Whisper on sung material collapses into a chant: 155 "oh" on Sweet Mystery, 159 "yeah" on
/// Shadows, 78 "so" mid-verse on 6 Human, confidence climbing to 0.99 as it goes, on six of the
/// seventeen takes in the corpus. WhisperKit's own defence is the temperature ladder, which was
/// measured and refused: random run to run, it re-decodes a genuinely repeated hook into junk
/// (Te Amo's `limpia` 9/9 → 1/9), and it costs a third more decode time.
///
/// This is the cheaper mechanism. WhisperKit hands every custom `LogitsFiltering` object the
/// tokens decoded so far before each sample. The brake folds those tokens to bare words (case
/// and punctuation dropped, so " Oh," and " oh" are one word and "," is invisible), and if the
/// tail of the word stream is the same one-to-four-word block repeated `maxRepeats` times in a
/// row, every token id that folds to the word that would extend the pattern once more is set to
/// -inf. The decoder is not re-run and nothing is random; it simply cannot say the sixth "oh"
/// and goes on listening. Measured on the seventeen takes: byte-identical across two runs, no
/// take worse than the greedy decode, every hook intact, total decode time 21% LOWER than without
/// it (the model stops spending 160 tokens a window on one word), and Heart Sing's two eaten
/// lines back ("All my troubles melt away / What would my life be like without you?").
///
/// Five repeats is the bar because three clips a real hook (`limpia` ×4 → 7/9) and four measured
/// no better than five. Nothing he sings repeats a word five times running except a vocalise,
/// and the run guard in `WhisperLyricsEngine.filterArtifacts` trims the capped remainder.
///
/// The fold table is built ONCE per pipeline, from the tokenizer's whole text vocabulary, so a
/// spelling the model has not used yet ("OH", " oh") is already in the suppression set. The
/// measurement's first case-folded variant built its table lazily and let each new spelling
/// through once; that is the gap this closes.
final class RepetitionBrake: LogitsFiltering {
    /// How many times a block may repeat before its next repeat is forbidden.
    static let maxRepeats = 5

    /// Longest block (in words) the brake watches for.
    static let maxPeriod = 4

    let specialTokenBegin: Int
    /// Folded word per text token id; ids whose token folds to nothing (pure punctuation or
    /// whitespace) are absent and are invisible to the pattern.
    private let foldOf: [Int: String]
    /// Every token id that folds to a given word.
    private let idsOf: [String: [Int]]

    /// Production: fold the whole text vocabulary through the loaded tokenizer.
    convenience init(tokenizer: WhisperTokenizer) {
        let specialTokenBegin = tokenizer.specialTokens.specialTokenBegin
        var table: [Int: String] = [:]
        table.reserveCapacity(specialTokenBegin)
        for id in 0..<specialTokenBegin {
            let word = RepetitionBrake.fold(tokenizer.decode(tokens: [id]))
            if !word.isEmpty { table[id] = word }
        }
        self.init(foldTable: table, specialTokenBegin: specialTokenBegin)
    }

    /// Testable: an explicit fold table.
    init(foldTable: [Int: String], specialTokenBegin: Int) {
        self.specialTokenBegin = specialTokenBegin
        self.foldOf = foldTable
        var reverse: [String: [Int]] = [:]
        for (id, word) in foldTable { reverse[word, default: []].append(id) }
        self.idsOf = reverse
    }

    /// Lowercase, letters and digits only. The same fold the artifact filter's run guard uses,
    /// so the two rules agree on what "the same word" means.
    static func fold(_ text: String) -> String {
        text.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    /// The word that would extend a repeating tail once too often, or nil when the tail is not
    /// a `maxRepeats`-fold repetition of any block up to `maxPeriod` words. Pure; the whole rule.
    static func forbiddenContinuation(
        after words: [String],
        maxRepeats: Int = RepetitionBrake.maxRepeats,
        maxPeriod: Int = RepetitionBrake.maxPeriod
    ) -> String? {
        guard maxRepeats > 0, maxPeriod > 0 else { return nil }
        for period in 1...maxPeriod {
            let need = period * maxRepeats
            guard words.count >= need else { continue }
            let tail = words[(words.count - need)...]
            let base = tail.startIndex
            var periodic = true
            var offset = period
            while offset < need {
                if tail[base + offset] != tail[base + offset - period] { periodic = false; break }
                offset += 1
            }
            if periodic { return tail[base + need - period] }
        }
        return nil
    }

    func filterLogits(_ logits: MLMultiArray, withTokens tokens: [Int]) -> MLMultiArray {
        var words: [String] = []
        words.reserveCapacity(tokens.count)
        for id in tokens where id < specialTokenBegin {
            if let word = foldOf[id] { words.append(word) }
        }
        guard let forbidden = Self.forbiddenContinuation(after: words),
              let ids = idsOf[forbidden] else { return logits }
        for id in ids {
            logits[[0, 0, NSNumber(value: id)]] = NSNumber(value: -Float.infinity)
        }
        return logits
    }
}
