import Foundation

/// Decodes Basic Pitch's frame + onset activation matrices into polyphonic note events.
///
/// A faithful Swift re-implementation of Spotify's `output_to_notes_polyphonic`,
/// `get_infered_onsets`, the `scipy.signal.argrelmax` peak-pick, and the "melodia trick"
/// (`basic_pitch/note_creation.py` @ spotify/basic-pitch fa5997af, Apache-2.0). Pure numeric
/// array logic — no I/O, no external calls. `infer_onsets`, `melodia_trick`, `energy_tol`, and
/// the ±1-frequency suppression match the upstream defaults. `constrain_frequency` and
/// pitch-bend are omitted in Phase 1 (default min/max freq are unbounded; pitch-bend deferred).
///
/// ## Complexity (2026-08-26, Chris's 13:48 take: the note decode was superlinear)
/// Upstream's melodia trick takes `np.argmax` over the WHOLE remaining-energy grid on every
/// candidate, so it costs O(K · F · P) for F frames (~86/s), P = 88 pitches and K candidates —
/// and K grows with F, so the decode was quadratic in the take length: 1.1 s for a 72 s take but
/// 95 s for an 828 s take in release (`sample`: 6062 of 6062 samples in the grid scan). The port
/// now keeps the same greedy order and the same tie-breaking through `FrameMaxIndex` (a per-frame
/// maximum plus a segment tree over frames), so a candidate costs O(log F) to find and
/// O(extent · P) to retire: O(F · P + K · (log F + extent · P)) overall. The note sequence is
/// unchanged — the corpus decode is byte-identical before and after (see the 0.1.16 notes).
enum BasicPitchDecoder {

    struct NoteEvent: Equatable {
        let startFrame: Int
        let endFrame: Int
        let freqIdx: Int       // 0…87; MIDI pitch = freqIdx + 21
        let amplitude: Double  // mean note activation over [startFrame, endFrame)
    }

    static let energyTol = 11   // upstream energy_tol
    static let nDiff = 2        // upstream get_infered_onsets n_diff

    /// `frames` / `onsets`: F × 88 activation matrices. Returns note events.
    static func outputToNotes(frames: [[Double]],
                              onsets rawOnsets: [[Double]],
                              onsetThresh: Double,
                              frameThresh: Double,
                              minNoteLen: Int) -> [NoteEvent] {
        guard var stage = onsetStage(frames: frames, onsets: rawOnsets, onsetThresh: onsetThresh,
                                     frameThresh: frameThresh, minNoteLen: minNoteLen) else { return [] }
        melodiaTrick(remaining: &stage.remaining, frames: frames, frameThresh: frameThresh,
                     minNoteLen: minNoteLen, events: &stage.events)
        return stage.events
    }

    // MARK: - Stage 1: onset-driven notes (faithful to upstream, unchanged)

    /// The onset-driven half of `output_to_notes_polyphonic`: infer onsets, peak-pick them, and
    /// walk each peak forward to its note's extent, zeroing the note's cells (and its ±1-semitone
    /// neighbours) out of the remaining energy. Returns the remaining energy the melodia trick
    /// starts from plus the notes accepted so far, or nil when the grid is degenerate.
    ///
    /// Factored out on 2026-08-26 (Chris's 13:48 take: the note decode was superlinear) so the
    /// indexed melodia trick and the DEBUG-only reference scan share one, unchanged, first stage.
    /// Cost O(F · P · nDiff) for the onset inference plus O(K₁ · extent) for the K₁ peaks.
    private static func onsetStage(frames: [[Double]],
                                   onsets rawOnsets: [[Double]],
                                   onsetThresh: Double,
                                   frameThresh: Double,
                                   minNoteLen: Int) -> (remaining: [[Double]], events: [NoteEvent])? {
        let nFrames = frames.count
        guard nFrames > 1, let nFreq = frames.first?.count, nFreq > 0 else { return nil }
        let maxFreqIdx = nFreq - 1

        // infer_onsets=True: combine predicted onsets with frame-difference onsets.
        let onsets = inferredOnsets(onsets: rawOnsets, frames: frames)

        // argrelmax along the time axis (strictly greater than both temporal neighbours),
        // gated by onsetThresh. Collected in row-major (time-major) order, then iterated in
        // reverse (descending time) — matching upstream `[::-1]`.
        var onsetPeaks: [(t: Int, f: Int)] = []
        for t in 1 ..< (nFrames - 1) {
            for f in 0 ..< nFreq {
                let v = onsets[t][f]
                if v > onsets[t - 1][f] && v > onsets[t + 1][f] && v >= onsetThresh {
                    onsetPeaks.append((t, f))
                }
            }
        }
        onsetPeaks.reverse()

        var remaining = frames   // remaining_energy = copy(frames)
        var events: [NoteEvent] = []

        for (noteStart, f) in onsetPeaks {
            if noteStart >= nFrames - 1 { continue }

            // Walk forward until energy stays below frameThresh for energyTol frames.
            var i = noteStart + 1
            var k = 0
            while i < nFrames - 1 && k < energyTol {
                if remaining[i][f] < frameThresh { k += 1 } else { k = 0 }
                i += 1
            }
            i -= k   // back to the last frame above threshold

            if i - noteStart <= minNoteLen { continue }

            zeroEnergy(&remaining, start: noteStart, end: i, freq: f, maxFreqIdx: maxFreqIdx)
            let amp = meanActivation(frames, start: noteStart, end: i, freq: f)
            events.append(NoteEvent(startFrame: noteStart, endFrame: i, freqIdx: f, amplitude: amp))
        }

        return (remaining, events)
    }

    // MARK: - Stage 2: the melodia trick, indexed

    /// Melodia trick: keep extracting the strongest remaining energy until it falls below
    /// `frameThresh`, growing each note forward and backward and zeroing what it consumed.
    ///
    /// Identical to upstream except for HOW the strongest cell is found. Upstream (and this port
    /// until 0.1.15) rescans the whole F × P grid per candidate; here `FrameMaxIndex` answers the
    /// same question — the first cell in row-major order holding the grid maximum — from a
    /// per-frame maximum and a segment tree, and only the frames a candidate touched are
    /// re-indexed. Decision anchor: 2026-08-26, Chris's 13:48 take: the note decode was
    /// superlinear. Constraints: the (frame, pitch) sequence must equal the scan's exactly,
    /// including on float ties (lowest frame, then lowest pitch), which is what
    /// `BasicPitchTranscriberTests` pins against `outputToNotesReferenceScan`. Complexity
    /// O(F · P) to build the index, then O(log F + extent · P) per candidate.
    private static func melodiaTrick(remaining: inout [[Double]],
                                     frames: [[Double]],
                                     frameThresh: Double,
                                     minNoteLen: Int,
                                     events: inout [NoteEvent]) {
        let nFrames = remaining.count
        guard nFrames > 1, let nFreq = remaining.first?.count, nFreq > 0 else { return }
        let maxFreqIdx = nFreq - 1
        var index = FrameMaxIndex(remaining)

        while true {
            let (iMid, maxVal) = index.best
            guard maxVal > frameThresh else { break }
            let f = index.pitch(of: iMid)
            remaining[iMid][f] = 0

            // forward pass
            var i = iMid + 1
            var k = 0
            while i < nFrames - 1 && k < energyTol {
                if remaining[i][f] < frameThresh { k += 1 } else { k = 0 }
                remaining[i][f] = 0
                if f < maxFreqIdx { remaining[i][f + 1] = 0 }
                if f > 0 { remaining[i][f - 1] = 0 }
                i += 1
            }
            let forwardEnd = i       // frames iMid+1 ..< forwardEnd were zeroed
            let iEnd = i - 1 - k

            // backward pass
            i = iMid - 1
            k = 0
            while i > 0 && k < energyTol {
                if remaining[i][f] < frameThresh { k += 1 } else { k = 0 }
                remaining[i][f] = 0
                if f < maxFreqIdx { remaining[i][f + 1] = 0 }
                if f > 0 { remaining[i][f - 1] = 0 }
                i -= 1
            }
            let backwardEnd = i      // frames backwardEnd+1 ... iMid-1 were zeroed
            let iStart = max(0, i + 1 + k)

            // Re-index every frame this candidate wrote to (always includes iMid). Only the
            // pitches f-1 ... f+1 changed, so a frame whose stored maximum sits elsewhere is
            // provably unaffected (values never rise) and is skipped inside `refresh`.
            index.refresh(frames: (backwardEnd + 1) ..< forwardEnd, in: remaining,
                          changedPitches: max(0, f - 1) ... min(maxFreqIdx, f + 1))

            if iEnd - iStart <= minNoteLen { continue }
            let amp = meanActivation(frames, start: iStart, end: max(iStart + 1, iEnd), freq: f)
            events.append(NoteEvent(startFrame: iStart, endFrame: max(iStart + 1, iEnd), freqIdx: f, amplitude: amp))
        }
    }

    /// The argmax index behind the melodia trick: for each frame, its maximum remaining energy and
    /// the FIRST pitch holding it; over frames, a segment tree whose root is the FIRST frame holding
    /// the grid maximum. Together they reproduce `np.argmax` on a row-major (F × P) grid exactly,
    /// ties included, without rescanning it.
    ///
    /// Decision anchor: 2026-08-26, Chris's 13:48 take: the note decode was superlinear.
    /// Constraints: comparisons are the scan's own strict `>` / `>=` on Double (no epsilon, no
    /// rounding), so equal values resolve to the lower frame, then the lower pitch, exactly as the
    /// scan resolved them; non-finite cells never win (NaN compares false; the scan skipped them
    /// too). Memory O(F): two per-frame arrays plus a tree of 2 · nextPowerOfTwo(F) nodes — never
    /// an entry per cell. Build O(F · P); `refresh` O(P + log F) per frame; `best` O(1).
    struct FrameMaxIndex {
        /// Per-frame maximum remaining energy (`-inf` for a frame with no finite cell).
        private(set) var rowMax: [Double]
        /// Per-frame first pitch attaining `rowMax`.
        private(set) var rowPitch: [Int]
        /// Leaf count: the smallest power of two ≥ frame count, so every node spans a contiguous,
        /// left-to-right frame range and "left wins ties" means "lower frame wins ties".
        private let size: Int
        /// Tree node values; node n has children 2n and 2n + 1, leaves start at `size`.
        private var treeValue: [Double]
        /// Frame index each node's value belongs to (-1 for a padding leaf).
        private var treeFrame: [Int32]

        init(_ grid: [[Double]]) {
            let nFrames = grid.count
            var s = 1
            while s < nFrames { s <<= 1 }
            size = s
            rowMax = [Double](repeating: -.infinity, count: nFrames)
            rowPitch = [Int](repeating: 0, count: nFrames)
            treeValue = [Double](repeating: -.infinity, count: 2 * s)
            treeFrame = [Int32](repeating: -1, count: 2 * s)
            for t in 0 ..< nFrames {
                let (v, p) = Self.rowArgmax(grid[t])
                rowMax[t] = v
                rowPitch[t] = p
                treeValue[s + t] = v
                treeFrame[s + t] = Int32(t)
            }
            if s > 1 {
                for n in stride(from: s - 1, through: 1, by: -1) { combine(n) }
            }
        }

        /// The first frame (lowest index) holding the grid maximum, and that maximum. The root
        /// is node 1 (for a single leaf, node 1 IS the leaf).
        var best: (frame: Int, value: Double) { (Int(treeFrame[1]), treeValue[1]) }

        /// The first pitch (lowest index) holding `frame`'s maximum.
        func pitch(of frame: Int) -> Int { rowPitch[frame] }

        /// Re-index `frames` after cells in `changedPitches` were zeroed. A frame whose stored
        /// argmax pitch lies outside `changedPitches` keeps its maximum untouched (that cell did
        /// not change and nothing rose), so its entry is provably still exact and is skipped.
        mutating func refresh(frames: Range<Int>, in grid: [[Double]], changedPitches: ClosedRange<Int>) {
            for t in frames where changedPitches.contains(rowPitch[t]) {
                let (v, p) = Self.rowArgmax(grid[t])
                rowMax[t] = v
                rowPitch[t] = p
                var n = size + t
                treeValue[n] = v
                n >>= 1
                while n >= 1 {
                    combine(n)
                    n >>= 1
                }
            }
        }

        /// First index of the row maximum with the scan's strict `>`: ties go to the lower pitch,
        /// NaN never wins. Returns (-inf, 0) for an empty or all-NaN row.
        private static func rowArgmax(_ row: [Double]) -> (Double, Int) {
            var best = -Double.infinity
            var bestPitch = 0
            for f in 0 ..< row.count {
                let v = row[f]
                if v > best { best = v; bestPitch = f }
            }
            return (best, bestPitch)
        }

        /// Node = left child unless the right child is strictly greater: ties go left (lower frame).
        private mutating func combine(_ n: Int) {
            let l = 2 * n, r = 2 * n + 1
            if treeValue[l] >= treeValue[r] {
                treeValue[n] = treeValue[l]
                treeFrame[n] = treeFrame[l]
            } else {
                treeValue[n] = treeValue[r]
                treeFrame[n] = treeFrame[r]
            }
        }
    }

    // MARK: - Helpers (faithful to upstream)

    /// `get_infered_onsets`: max of the predicted onsets and the (rescaled, clamped) minimum
    /// forward frame-difference over 1…nDiff steps.
    private static func inferredOnsets(onsets: [[Double]], frames: [[Double]]) -> [[Double]] {
        let nFrames = frames.count
        guard nFrames > 0, let nFreq = frames.first?.count else { return onsets }

        var frameDiff = [[Double]](repeating: [Double](repeating: 0, count: nFreq), count: nFrames)
        for t in 0 ..< nFrames {
            for f in 0 ..< nFreq {
                if t < nDiff { frameDiff[t][f] = 0; continue }
                // min over n in 1...nDiff of (frames[t] - frames[t-n])
                var minDiff = Double.greatestFiniteMagnitude
                for n in 1 ... nDiff {
                    minDiff = Swift.min(minDiff, frames[t][f] - frames[t - n][f])
                }
                frameDiff[t][f] = Swift.max(0, minDiff)
            }
        }

        let onsetsMax = onsets.flatMap { $0 }.max() ?? 0
        let diffMax = frameDiff.flatMap { $0 }.max() ?? 0
        if diffMax > 0 {
            let scale = onsetsMax / diffMax
            for t in 0 ..< nFrames { for f in 0 ..< nFreq { frameDiff[t][f] *= scale } }
        }

        var out = onsets
        for t in 0 ..< nFrames { for f in 0 ..< nFreq { out[t][f] = Swift.max(onsets[t][f], frameDiff[t][f]) } }
        return out
    }

    private static func zeroEnergy(_ m: inout [[Double]], start: Int, end: Int, freq: Int, maxFreqIdx: Int) {
        for r in start ..< end {
            m[r][freq] = 0
            if freq < maxFreqIdx { m[r][freq + 1] = 0 }
            if freq > 0 { m[r][freq - 1] = 0 }
        }
    }

    private static func meanActivation(_ frames: [[Double]], start: Int, end: Int, freq: Int) -> Double {
        guard end > start else { return 0 }
        var sum = 0.0
        for r in start ..< end { sum += frames[r][freq] }
        return sum / Double(end - start)
    }

#if DEBUG
    // MARK: - Reference scan (DEBUG only: the pre-0.1.16 decode, kept as the oracle)

    /// The decode exactly as shipped through 0.1.15: the same first stage, then the melodia trick
    /// with a full-grid `argmax2D` rescan per candidate. Kept under DEBUG so the test target can
    /// pin the indexed decode to it on grids with deliberate ties; never compiled into a release.
    /// Decision anchor: 2026-08-26, Chris's 13:48 take: the note decode was superlinear.
    /// Complexity O(K · F · P) — the reason it is the oracle and not the product.
    static func outputToNotesReferenceScan(frames: [[Double]],
                                           onsets rawOnsets: [[Double]],
                                           onsetThresh: Double,
                                           frameThresh: Double,
                                           minNoteLen: Int) -> [NoteEvent] {
        guard var stage = onsetStage(frames: frames, onsets: rawOnsets, onsetThresh: onsetThresh,
                                     frameThresh: frameThresh, minNoteLen: minNoteLen) else { return [] }
        let nFrames = frames.count
        let maxFreqIdx = frames[0].count - 1

        while true {
            guard let (iMid, f, maxVal) = argmax2D(stage.remaining), maxVal > frameThresh else { break }
            stage.remaining[iMid][f] = 0

            // forward pass
            var i = iMid + 1
            var k = 0
            while i < nFrames - 1 && k < energyTol {
                if stage.remaining[i][f] < frameThresh { k += 1 } else { k = 0 }
                stage.remaining[i][f] = 0
                if f < maxFreqIdx { stage.remaining[i][f + 1] = 0 }
                if f > 0 { stage.remaining[i][f - 1] = 0 }
                i += 1
            }
            let iEnd = i - 1 - k

            // backward pass
            i = iMid - 1
            k = 0
            while i > 0 && k < energyTol {
                if stage.remaining[i][f] < frameThresh { k += 1 } else { k = 0 }
                stage.remaining[i][f] = 0
                if f < maxFreqIdx { stage.remaining[i][f + 1] = 0 }
                if f > 0 { stage.remaining[i][f - 1] = 0 }
                i -= 1
            }
            let iStart = max(0, i + 1 + k)

            if iEnd - iStart <= minNoteLen { continue }
            let amp = meanActivation(frames, start: iStart, end: max(iStart + 1, iEnd), freq: f)
            stage.events.append(NoteEvent(startFrame: iStart, endFrame: max(iStart + 1, iEnd), freqIdx: f, amplitude: amp))
        }

        return stage.events
    }

    /// The pre-0.1.16 grid scan: first cell in row-major order holding the maximum (strict `>`).
    private static func argmax2D(_ m: [[Double]]) -> (Int, Int, Double)? {
        var best: (Int, Int, Double)? = nil
        for t in 0 ..< m.count {
            for f in 0 ..< m[t].count {
                let v = m[t][f]
                if best == nil || v > best!.2 { best = (t, f, v) }
            }
        }
        return best
    }
#endif
}
